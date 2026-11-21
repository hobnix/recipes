#!/usr/bin/env bash
# recipe: Paperless-ngx: your paper documents scanned, read by OCR and searchable in the browser
# recipe.de: Paperless-ngx: deine Papierdokumente gescannt, per OCR gelesen und im Browser durchsuchbar
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "paperless-ngx" with Docker inside and runs
# Paperless-ngx the way its makers ship it (their docker-compose file for
# Postgres, pinned to one release and checked with sha256).
#   documents           on the bulk disks: the folder /bulk/sensitive/<share>
#                       (default paperless), mounted at /mnt/paperless
#                       (media/, export/, consume/).
#   database            on the SSD pool, inside the container (/opt/paperless-ngx/postgres).
#   search index and settings of the app: /opt/paperless-ngx/data
#   scanner share       optional: /bulk/shares/<share>-consume, mounted at
#                       /mnt/paperless-consume; Paperless reads its files from there.
# The admin is "admin"; its password, the secret key and the database
# password are made once (/opt/paperless-ngx/.env, root only) and the admin
# password is printed once. PAPERLESS_URL is only set when you give a public
# address (needed for a public route: allowed hosts and CSRF).
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# RECIPE_SKIP_STORAGE=1 (documents stay in the container) RECIPE_SKIP_PULL=1 (no
# download of the images and no start: only the compose files are written and checked).

PAPERLESS_VERSION=3.5.1
PAPERLESS_COMPOSE_BASE=https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/v$PAPERLESS_VERSION/docker/compose
PAPERLESS_COMPOSE_SHA256=85206b8ae6cd74db70998de6479b4c1f7b50c077772a1af2c026c9ecb35b689c        # docker-compose.postgres.yml
PAPERLESS_COMPOSE_TIKA_SHA256=5230d1e09125f4bdf4b3c3e373aca70a9a86a2d520b3af3efd915101b51a154c   # docker-compose.postgres-tika.yml

scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-paperless-ngx}
# shellcheck source=/dev/null
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  create a folder under /bulk/sensitive for the documents (asks for its name, default paperless) and mount it at /mnt/paperless"
  say "  if you say yes: a share <name>-consume under /bulk/shares that a scanner can write to, mounted at /mnt/paperless-consume"
  printf '%s\n' "$(t "  install Docker inside and start Paperless-ngx %s from its official docker-compose file (checked with sha256)" "$PAPERLESS_VERSION")"
  say "  optionally Tika and Gotenberg for office documents (Word, Excel, e-mails)"
  say "  optionally ask for a public address (PAPERLESS_URL), only needed if the page gets a public route"
  say "  make the secret key, the database password and the admin password once (in /opt/paperless-ngx/.env, root only)"
  say "  keep the database on the SSD pool (/opt/paperless-ngx/postgres in the container)"
  say "  put the container in the nightly backup with a database dump"
  exit 0
fi

port_setting "Paperless-ngx" 8000
# shellcheck disable=SC2154  # a_name comes from _lib.sh
setting SHARE "Name of the folder for the documents (under /bulk/sensitive, also the share's name)" paperless paperless "$a_name"
ocr_default=eng
[ "$(setting_get language 2>/dev/null || true)" != de ] || ocr_default=deu+eng
setting OCR "OCR languages, Tesseract codes joined with + (built in: eng deu fra ita spa; others are downloaded at each start)" "$ocr_default" "$ocr_default" '[a-z]{3}(_[a-z]+)?(\+[a-z]{3}(_[a-z]+)?)*'
tz_default=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
setting TZ "Time zone of Paperless-ngx" "$tz_default" "$tz_default" '[A-Za-z_]+(/[A-Za-z0-9_+-]+)*'
setting OFFICE "Also import office documents and e-mails (Tika and Gotenberg, about 1 GB more RAM)? yes or no" no no 'yes|no'
setting SCAN "Share the consume folder over the network, so a scanner can save into it? yes or no" no no 'yes|no'
setting URL "Public address of Paperless-ngx, only if it gets a public route (for example https://docs.example.com); empty for none" "" "" '(https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?)?'
# shellcheck disable=SC2153  # SHARE is set by setting(), share is the same value in lower case
share=$SHARE

ensure_container "$ct" 4096 --docker
fixed_address "$ct"
wait_internet "$ct"

step "Storage for the documents"
if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE): the documents stay inside the container"
  incus exec "$ct" -- mkdir -p /mnt/paperless </dev/null
elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/mnt/paperless")] | length')" != 0 ]; then
  ok "/mnt/paperless is mounted already"
else
  spin "$(t 'Creating /bulk/sensitive/%s and mounting it at /mnt/paperless' "$share")" \
    bash "$scripts/manage-ct.sh" "$ct" --add-storage sensitive "$share" /mnt/paperless
fi
incus exec "$ct" -- sh -c 'touch /mnt/paperless/.hs-write-test && rm /mnt/paperless/.hs-write-test' </dev/null 2>/dev/null ||
  fail "$(t "The container can't write to /mnt/paperless. Look at the storage of '%s' in: hs ct list" "$ct")"
in_ct "Preparing the folders" 'mkdir -p /mnt/paperless/media /mnt/paperless/export /mnt/paperless/consume /opt/paperless-ngx/data /opt/paperless-ngx/postgres'

consume=/mnt/paperless/consume
poll=0
if [ "$SCAN" = yes ]; then
  step "Scanner share"
  if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
    note "skipped (RECIPE_SKIP_STORAGE): the consume folder stays inside the container"
    incus exec "$ct" -- mkdir -p /mnt/paperless-consume </dev/null
  elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/mnt/paperless-consume")] | length')" != 0 ]; then
    ok "/mnt/paperless-consume is mounted already"
  else
    spin "$(t 'Creating /bulk/shares/%s-consume and mounting it at /mnt/paperless-consume' "$share")" \
      bash "$scripts/manage-ct.sh" "$ct" --add-storage shares "$share-consume" /mnt/paperless-consume
    wait_internet "$ct"
  fi
  incus exec "$ct" -- sh -c 'touch /mnt/paperless-consume/.hs-write-test && rm /mnt/paperless-consume/.hs-write-test' </dev/null 2>/dev/null ||
    fail "$(t "The container can't write to /mnt/paperless-consume. Look at the storage of '%s' in: hs ct list" "$ct")"
  consume=/mnt/paperless-consume
  poll=60
else
  dev=$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices | to_entries[] | select(.value.path == "/mnt/paperless-consume") | .key][0] // empty')
  if [ -n "$dev" ]; then
    note "$(t 'The share %s-consume stays, but Paperless-ngx now reads /mnt/paperless/consume. Remove the share by hand with: hs ct %s --remove-storage %s' "$share" "$ct" "$dev")"
  fi
fi

install_docker

step "Paperless-ngx"
cache=$state/paperless-ngx
mkdir -p "$cache"
variant=postgres
sum=$PAPERLESS_COMPOSE_SHA256
[ "$OFFICE" != yes ] || { variant=postgres-tika; sum=$PAPERLESS_COMPOSE_TIKA_SHA256; }
fetch_pinned "compose-$variant" "$PAPERLESS_COMPOSE_BASE/docker-compose.$variant.yml" "$sum" "$cache/docker-compose.$variant-$PAPERLESS_VERSION.yml" "$PAPERLESS_VERSION"
spin "Copying the docker-compose file into the container" incus file push -q --create-dirs --mode 0644 "$cache/docker-compose.$variant-$PAPERLESS_VERSION.yml" "$ct/opt/paperless-ngx/docker-compose.yml"

# the secrets are made once, inside the container: the database password is fixed at the first database start
fresh=false
incus exec "$ct" -- test -s /opt/paperless-ngx/.env </dev/null || fresh=true
# the snippet runs inside the container: its $ must not expand here
# shellcheck disable=SC2016
in_ct "Making the secrets (once)" '
  cd /opt/paperless-ngx
  if [ ! -s .env ]; then
    key=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64 || true)
    db=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 40 || true)
    admin=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20 || true)
    [ -n "$key" ] && [ -n "$db" ] && [ -n "$admin" ]
    umask 077
    { echo "COMPOSE_PROJECT_NAME=paperless"; echo "PAPERLESS_SECRET_KEY=$key"; echo "PAPERLESS_DBPASS=$db"
      echo "PAPERLESS_ADMIN_USER=admin"; echo "PAPERLESS_ADMIN_PASSWORD=$admin"; } > .env.new
    chmod 600 .env.new && mv .env.new .env
  fi
  chmod 600 .env'

# extra OCR languages (the image has eng deu fra ita spa): tesseract codes with _ written as -
extra=""
IFS=+ read -ra ocr_codes <<< "$OCR"
for code in "${ocr_codes[@]}"; do
  case "$code" in eng|deu|fra|ita|spa) continue ;; esac
  extra="${extra:+$extra }${code//_/-}"
done

ensure_file /opt/paperless-ngx/docker-compose.env "the settings of Paperless-ngx" <<ENVFILE
USERMAP_UID=1000
USERMAP_GID=100
PAPERLESS_TIME_ZONE=$TZ
PAPERLESS_OCR_LANGUAGE=$OCR
PAPERLESS_OCR_LANGUAGES=$extra
PAPERLESS_CONSUMER_POLLING_INTERVAL=$poll
PAPERLESS_CONSUMER_RECURSIVE=true
${URL:+PAPERLESS_URL=$URL}
ENVFILE

# ${PAPERLESS_...} stay literal: docker compose fills them from .env
ensure_file /opt/paperless-ngx/docker-compose.override.yml "the compose override" <<OVERRIDE
services:
  db:
    environment:
      POSTGRES_PASSWORD: \${PAPERLESS_DBPASS}
    volumes: !override
      - /opt/paperless-ngx/postgres:/var/lib/postgresql
  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:$PAPERLESS_VERSION
    ports: !override
      - "$PORT:8000"
    volumes: !override
      - /opt/paperless-ngx/data:/usr/src/paperless/data
      - /mnt/paperless/media:/usr/src/paperless/media
      - /mnt/paperless/export:/usr/src/paperless/export
      - $consume:/usr/src/paperless/consume
    environment:
      PAPERLESS_SECRET_KEY: \${PAPERLESS_SECRET_KEY}
      PAPERLESS_DBPASS: \${PAPERLESS_DBPASS}
      PAPERLESS_ADMIN_USER: \${PAPERLESS_ADMIN_USER}
      PAPERLESS_ADMIN_PASSWORD: \${PAPERLESS_ADMIN_PASSWORD}
OVERRIDE
# -q: without it "config" would print the secrets
in_ct "Checking the compose files" 'cd /opt/paperless-ngx && docker compose config -q'

pull='cd /opt/paperless-ngx && docker compose pull -q'
start='cd /opt/paperless-ngx && docker compose up -d --remove-orphans'
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Paperless-ngx not started"
else
  in_ct "Downloading Paperless-ngx (about 2 GB)" "$pull"
  in_ct "Starting Paperless-ngx" "$start"
  # the first start runs the migrations and downloads extra OCR languages
  wait_page Paperless-ngx 'docker compose -f /opt/paperless-ngx/docker-compose.yml logs --tail 50' --path /accounts/login/ --ok --tries 180
  ok "$(t 'Paperless-ngx %s is running' "$PAPERLESS_VERSION")"
fi

step "Backup"
# the database runs in a Docker container of its own: a dump (hs-dump) is made right before each backup
install_dump_tool
backup_with_dump paperless-ngx "/usr/local/sbin/hs-dump postgres-compose paperless-ngx /opt/paperless-ngx db paperless paperless"
ok "$(t "'%s' is in the nightly backup with a database dump (hs backup ct %s off: take it out)" "$ct" "$ct")"
note "$(t 'The documents are in the share %s: include it in the backup with: hs backup %s on' "$share" "$share")"

admin_pw=""
if $fresh; then admin_pw=$(incus exec "$ct" -- sed -n 's/^PAPERLESS_ADMIN_PASSWORD=//p' /opt/paperless-ngx/.env </dev/null 2>/dev/null || true); fi
unc="\\\\$(hostname)\\$share-consume"
recipe_facts web
if [ -n "$admin_pw" ]; then
  kv "Login" "admin / $admin_pw"
else
  kv "Login" "admin (password made at the first run; also in /opt/paperless-ngx/.env in the container)"
fi
kv "Documents" "/bulk/sensitive/$share"
if [ "$SCAN" = yes ]; then kv "Scanner share" "$unc"; fi
declare_service paperless-ngx Paperless-ngx paperless-ngx private-ok Apps "Documents with OCR and search"
box <<DONE
$(if [ -n "$admin_pw" ]; then say "1. The password is shown only now: log in, change it (profile menu, top right), keep it safe."; else say "1. Log in as admin; the password was shown at the first run (it is also in /opt/paperless-ngx/.env in the container)."; fi)
$(say "2. Paperless-ngx holds sensitive documents: keep it private; on the internet only behind a login (see the guide).")
$(if [ "$SCAN" = yes ]; then t '3. Scanner: save to the share %s (user with write access: hs manage-shares).' "$unc"; fi)
$(if [ -n "$extra" ]; then say "4. Extra OCR languages are downloaded at every start (needs internet)."; fi)
$(docs_hint paperless-ngx)
DONE
