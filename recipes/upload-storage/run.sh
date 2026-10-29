#!/usr/bin/env bash
# recipe: Upload storage: your own file sync and upload server (Seafile or ownCloud), with apps for phone and PC
# recipe.de: Upload-Speicher: dein eigener Server zum Hochladen und Synchronisieren von Dateien (Seafile oder ownCloud), mit Apps für Handy und PC
# kind: generic
# needs: docker share
# uses: -
# input: form
# ask: PRODUCT|Which one: seafile (fast, syncs libraries, stores blocks) or owncloud (plain files, familiar Dropbox-like web interface)|choice:seafile,owncloud|seafile||
# ask: DOMAIN|Public host name, if it should be reachable from the internet (empty: none; the route is made with hs services apply)|text||(([a-z0-9-]+\.)+[a-z]{2,})?|
# ask: ADMIN_EMAIL|E-mail address of the first administrator (the Seafile login name)|text|admin@example.com|[^@ ]+@[^@ ]+|PRODUCT=seafile
set -euo pipefail

# What it does: creates the container "upload-storage" with Docker inside and runs
# the product you choose the way its makers ship it (docker compose: the server,
# a MariaDB database and Redis).
#   uploaded files   on the bulk disks: the folder /bulk/sensitive/upload-storage,
#                    mounted at /mnt/upload-storage. "sensitive" because the product
#                    manages these files (Seafile even stores them as blocks); over
#                    the network share they can be read, not changed.
#   database         on the SSD pool, inside the container (/opt/upload-storage/mysql).
# The first administrator is created at the first start with a random password that
# is kept in /opt/upload-storage/.secrets inside the container (root only).
# One container holds ONE product: asking for the other one later is refused (run
# the recipe again with --name <another container> to have both).
# Public name (optional, only asked when a reverse proxy is set up): DOMAIN, e.g. files.example.com. The product is then told its address is
# https://<DOMAIN> (Seafile: SERVICE_URL, FILE_SERVER_ROOT, CSRF_TRUSTED_ORIGINS; without them its login answers 403 "CSRF verification
# failed"), and the service is declared public-ok with that name and wants the reverse proxy. No route is made here: `hs services apply`
# does that (on a public proxy it asks for the host name to be typed); in a terminal this recipe offers to run it.
# Without a name: private only.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# RECIPE_SKIP_STORAGE=1 (files stay in the container) RECIPE_SKIP_PULL=1 (no
# download of the images and no start: only the compose files are written and checked).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-upload-storage}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  ask which product: Seafile or ownCloud"
  say "  create a folder under /bulk/sensitive for the files (asks for its name, default upload-storage) and mount it at /mnt/upload-storage"
  say "  install Docker inside and start the product with MariaDB and a cache (docker compose, a few hundred MB to download)"
  say "  keep the database on the SSD pool (/opt/upload-storage/mysql in the container)"
  exit 0
fi

setting PRODUCT "Which one: seafile or owncloud" seafile seafile "seafile|owncloud"
[ "$PRODUCT" = seafile ] && ADMIN_EMAIL_DEFAULT=admin@example.com || ADMIN_EMAIL_DEFAULT=admin
if [ "$PRODUCT" = seafile ]; then
  setting ADMIN_EMAIL "E-mail address of the first administrator (the Seafile login name)" "$ADMIN_EMAIL_DEFAULT" "$ADMIN_EMAIL_DEFAULT" '[^@ ]+@[^@ ]+'
else
  ADMIN_EMAIL=admin
fi
case "$PRODUCT" in seafile) title=Seafile; inner=80; ping_path=/api2/ping/; ping_match=pong ;;
                   *)       title=ownCloud; inner=8080; ping_path=/status.php; ping_match='"installed":true' ;; esac
port_setting "$title" 80
DOMAIN=""
if [ -n "$(setting_get reverseProxy 2>/dev/null || true)" ]; then
  setting DOMAIN "Public host name for $title (like files.example.com), empty for none" "" "" '(([a-z0-9-]+\.)+[a-z]{2,})?'
fi
setting SHARE "Name of the folder for the files (under /bulk/sensitive, also the share's name)" upload-storage upload-storage "$a_name"
share=$SHARE
ensure_container "$ct" 4096 --docker
fixed_address "$ct"
wait_internet "$ct"

# one container, one product (the data of the two do not mix)
have=$(incus exec "$ct" -- cat /opt/upload-storage/product </dev/null 2>/dev/null || true)
if [ -n "$have" ] && [ "$have" != "$PRODUCT" ]; then
  fail "$(t "'%s' runs %s already. For %s use a container of its own: hs recipe upload-storage --name <container>" "$ct" "$have" "$PRODUCT")"
fi

step "Storage for the files"
if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE): the files stay inside the container"
  incus exec "$ct" -- mkdir -p /mnt/upload-storage </dev/null
elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/mnt/upload-storage")] | length')" != 0 ]; then
  ok "/mnt/upload-storage is mounted already"
else
  spin "$(t 'Creating /bulk/sensitive/%s and mounting it at /mnt/upload-storage' "$share")" \
    bash "$scripts/manage-ct.sh" "$ct" --add-storage sensitive "$share" /mnt/upload-storage
fi
incus exec "$ct" -- sh -c 'touch /mnt/upload-storage/.hs-write-test && rm /mnt/upload-storage/.hs-write-test' </dev/null 2>/dev/null ||
  fail "$(t "The container can't write to /mnt/upload-storage. Look at the storage of '%s' in: hs ct list" "$ct")"

install_docker

step "$title"
# the address people type in the browser (Seafile builds its links from it at the first start)
lan=$ip; [ "$PORT" = 80 ] || lan=$ip:$PORT
host=$lan; proto=http
trusted="$ip,$(hostname).local,$(hostname)"
if [ -n "$DOMAIN" ]; then host=$DOMAIN; proto=https; trusted="$DOMAIN,$trusted"; fi
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)

# Secrets are made once and never change (the database is initialised with them);
# .env is put together again at every run from them and the settings that may change.
in_ct "Writing the settings" '
  mkdir -p /opt/upload-storage/mysql && cd /opt/upload-storage
  if [ ! -s .secrets ]; then
    r() { tr -dc A-Za-z0-9 </dev/urandom | head -c "$1" || true; }
    { echo "DB_PASSWORD=$(r 32)"; echo "DB_ROOT_PASSWORD=$(r 32)"; echo "ADMIN_PASSWORD=$(r 20)"; echo "JWT_KEY=$(r 40)"; } > .secrets.new
    chmod 600 .secrets.new && mv .secrets.new .secrets
  fi
  { cat .secrets
    printf "HOST=%s\nPORT=%s\nTRUSTED=%s\nTZ=%s\nADMIN_EMAIL=%s\nPROTO=%s\n" "$1" "$2" "$3" "$4" "$5" "$7"
  } > .env.new
  chmod 600 .env.new && mv .env.new .env
  echo "$6" > product
  ' "$host" "$PORT" "$trusted" "$tz" "$ADMIN_EMAIL" "$PRODUCT" "$proto"

if [ "$PRODUCT" = seafile ]; then
  compose=$(cat <<'EOF'
services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /opt/upload-storage/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 20
  memcached:
    image: memcached:1.6.18
    restart: unless-stopped
    entrypoint: memcached -m 256
  seafile:
    image: seafileltd/seafile-mc:12.0-latest
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    volumes:
      - /mnt/upload-storage:/shared
    environment:
      DB_HOST: db
      DB_USER: seafile
      DB_PASSWORD: ${DB_PASSWORD}
      DB_ROOT_PASSWD: ${DB_ROOT_PASSWORD}
      TIME_ZONE: ${TZ}
      INIT_SEAFILE_ADMIN_EMAIL: ${ADMIN_EMAIL}
      INIT_SEAFILE_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      SEAFILE_SERVER_HOSTNAME: ${HOST}
      SEAFILE_SERVER_PROTOCOL: ${PROTO}
      JWT_PRIVATE_KEY: ${JWT_KEY}
    depends_on:
      db:
        condition: service_healthy
      memcached:
        condition: service_started
EOF
)
else
  compose=$(cat <<'EOF'
services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    command: ["--max-allowed-packet=128M", "--innodb-log-file-size=64M"]
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_USER: owncloud
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: owncloud
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /opt/upload-storage/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 20
  redis:
    image: redis:7
    restart: unless-stopped
  owncloud:
    image: owncloud/server:10.15
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    volumes:
      - /mnt/upload-storage:/mnt/data
    environment:
      OWNCLOUD_DOMAIN: ${HOST}
      OWNCLOUD_TRUSTED_DOMAINS: ${TRUSTED}
      ADMIN_USERNAME: admin
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      HTTP_PORT: "8080"
      OWNCLOUD_DB_TYPE: mysql
      OWNCLOUD_DB_HOST: db
      OWNCLOUD_DB_NAME: owncloud
      OWNCLOUD_DB_USERNAME: owncloud
      OWNCLOUD_DB_PASSWORD: ${DB_PASSWORD}
      OWNCLOUD_MYSQL_UTF8MB4: "true"
      OWNCLOUD_REDIS_ENABLED: "true"
      OWNCLOUD_REDIS_HOST: redis
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
EOF
)
fi
in_ct "Writing docker-compose.yml" '
  cd /opt/upload-storage
  printf "%s\n" "$1" > docker-compose.yml.new && mv docker-compose.yml.new docker-compose.yml
  docker compose config -q' "$compose"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, $title not started"
else
  in_ct "Downloading $title" 'cd /opt/upload-storage && docker compose pull -q'
  in_ct "Starting $title" 'cd /opt/upload-storage && docker compose up -d --remove-orphans'
  wait_page "$title" 'docker compose -f /opt/upload-storage/docker-compose.yml logs --tail 50' --path "$ping_path" --match "$ping_match" --tries 240
  if [ "$PRODUCT" = seafile ]; then
    # Seafile keeps its own address in seahub_settings.py (written once, from the first start): bring it in line with the name, and trust
    # both origins (the public name and the LAN address) for the login form; it restarts only when the file changed
    in_ct "Setting the address of Seafile" '
      f=/mnt/upload-storage/seafile/conf/seahub_settings.py
      [ -f "$f" ] || exit 0
      before=$(md5sum < "$f")
      if [ -n "$1" ]; then
        sed -i -E "s|^SERVICE_URL = .*|SERVICE_URL = \"https://$1\"|; s|^FILE_SERVER_ROOT = .*|FILE_SERVER_ROOT = \"https://$1/seafhttp\"|" "$f"
        origins="\"https://$1\", \"http://$2\""
      else
        origins="\"http://$2\""
      fi
      sed -i "/^CSRF_TRUSTED_ORIGINS = /d" "$f"
      printf "CSRF_TRUSTED_ORIGINS = [%s]\n" "$origins" >> "$f"
      if [ "$before" != "$(md5sum < "$f")" ]; then cd /opt/upload-storage && docker compose restart seafile; fi
      ' "$DOMAIN" "$lan"
    wait_page "$title" 'docker compose -f /opt/upload-storage/docker-compose.yml logs --tail 50' --path "$ping_path" --match "$ping_match" --tries 120 --plain
  fi
fi

unc="\\\\$(hostname)\\$share"
recipe_facts web
export SERVICE_PUBLIC_NAME=$DOMAIN
declare_service "$ct" "$title" cloud-arrow-up private-ok Apps "File upload and sync" "$PORT"
kv "Files" "/bulk/sensitive/$share"
kv "Share" "$unc"
if [ -n "$DOMAIN" ]; then
  kv "Public name" "https://$DOMAIN"
  if interactive && confirm "$(t "Make the route for %s on the reverse proxy now (hs services apply)?" "$DOMAIN")"; then
    bash "$scripts/services.sh" apply || warn "The route was not made. Look at: hs services plan"
  fi
  public_text=$(t 'Public name %s: the route is made by  hs services apply  (it asks you to type the host name). Until then use the home address.' "$DOMAIN")
else
  public_text=$(say 'Not public: to give it a public name run  hs recipe upload-storage --ask  and type one (needs the reverse proxy).')
fi
if [ "$PRODUCT" = seafile ]; then
  login_text=$(t 'Log in as %s' "$ADMIN_EMAIL")
  files_text=$(say 'Seafile stores files as blocks: the share shows them, but only Seafile (web, apps, sync client) shows them as files.')
else
  login_text=$(say 'Log in as admin')
  files_text=$(say 'The files of every user are plain files under  <folder>/files/<user>/files  (read only over the share).')
fi
box <<DONE
$(t '1. Read the first password:  incus exec %s -- grep ADMIN_PASSWORD /opt/upload-storage/.secrets' "$ct")
$(t '2. Open %s . %s, then change the password (Profile -> Settings) and add the other users.' "$(web)" "$login_text")
$(t '3. Phone and PC: install the app or sync client of the product, server address  %s . The device must be in the home network or connected through Tailscale.' "$(web)")
$files_text
$public_text
$(docs_hint containers-and-apps)
DONE
