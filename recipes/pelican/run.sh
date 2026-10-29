#!/usr/bin/env bash
# recipe: Pelican: game servers with a web panel (Panel and Wings, two containers)
# recipe.de: Pelican: Spieleserver mit einem Web-Panel (Panel und Wings, zwei Container)
# kind: personal
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the two containers and installs both parts itself, from the makers' releases (pinned below, checked
# with their checksum), then does everything the guide "Pelican Panel und Wings" lists around them:
#   pelican-panel   nginx + PHP-FPM + Composer, the Panel from panel.tar.gz in /opt/pelican-panel, a queue worker and a scheduler
#                   (systemd). The database is SQLite, chosen in the Panel's web installer: no database server to keep running or
#                   back up, and the Panel's own installer offers it. Fixed address, APP_URL set to it.
#   pelican-wings   Docker inside, the Wings binary in /usr/local/bin/wings and its unit, /etc/pelican for the config the Panel
#                   gives you, a 100 GB disk and the folder /bulk/sensitive/pelican-backups for backups
# Nothing asks anything, so the recipe also runs from the web interface.
# Updates: raise the pins below. A run downloads and installs only what differs from the stamp of the last run
# (hs recipe pelican --check says what would change). Containers set up earlier by hand or by another installer are ADOPTED: kept
# as they are, their files untouched; `hs recipe pelican --update` moves them to the pinned release.
# What stays for you, in the browser: the Panel's installer, the node, and the Zoraxy rules. The closing text lists them.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
panel=${RECIPE_PANEL:-pelican-panel}
wings=${RECIPE_WINGS:-pelican-wings}
ct=$panel

# The pins (raise them to update; the checksums are the ones GitHub shows for the release files)
PANEL_VERSION=v1.0.0-rc.2
PANEL_SHA256=d87f24c19b2511dd4a686cee0a9ad8e99e227792101f651ec7a8102d8a20ae0e
WINGS_VERSION=v1.0.0-rc.1
WINGS_SHA256=19dda386e02041da1f1fbcc73f34e4bb01c1fbc2d499aac79a6be3a51ba7f0e8   # wings_linux_amd64
PANEL_URL=https://github.com/pelican-dev/panel/releases/download/$PANEL_VERSION/panel.tar.gz
WINGS_URL=https://github.com/pelican-dev/wings/releases/download/$WINGS_VERSION/wings_linux_amd64
PACKAGES_PIN=1   # raise when the list of packages below changes

. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

UPDATE=false
for a in "$@"; do [ "$a" != --update ] || UPDATE=true; done
cache=$state/pelican
exists() { incus info "$1" >/dev/null 2>&1; }

# Work on one of the two containers: the helpers of _lib.sh read $ct, $conf, $stamps and $existed.
use_ct() {
  ct=$1; conf="$state/recipe-$ct.conf"; stamps="$state/recipe-$ct.stamps"
  existed=false; ! exists "$ct" || existed=true
}
# adopted <key> <path in the container>: installed before this recipe wrote a stamp (no stamp, the file is there), or already marked
adopted() {
  local s; s=$(stamp_get "$1")
  [ "$s" = adopted ] && return 0
  [ -z "$s" ] && exists "$ct" && incus exec "$ct" -- test -e "$2" </dev/null
}
# like piece, but an adopted install counts as current until --update
pel_piece() {   # pel_piece <key> <wanted> <label> <path that tells an install by hand>
  if adopted "$1" "$4" && ! $UPDATE; then
    ! $CHECK || say "kept           $3 (adopted as it is; hs recipe pelican --update moves it to $2)"
    return 0
  fi
  piece "$1" "$2" "$3"
}

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create '%s' and '%s' unless they exist" "$panel" "$wings")"
  say "  give both a fixed address (.30 to .39) if UniFi is connected (hs net setup)"
  printf '%s\n' "$(t "  download the Panel %s (panel.tar.gz) and the Wings binary %s from GitHub, only when the pin changed, and check their checksums" "$PANEL_VERSION" "$WINGS_VERSION")"
  printf '%s\n' "$(t "  install nginx, PHP-FPM and Composer from the package sources into '%s' and Docker into '%s'" "$panel" "$wings")"
  printf '%s\n' "$(t "  set the disk of '%s' to 100 GB and mount /bulk/sensitive/pelican-backups at /var/lib/pelican/backups" "$wings")"
  printf '%s\n' "$(t "  pass /dev/ntsync (Wine's fast thread sync) into '%s'" "$wings")"
  say "  set the Panel's APP_URL to its address, until you give it a public one"
  exit 0
fi

# --check: what would change, nothing is done (stamps are only read)
if $CHECK; then
  for name in "$panel" "$wings"; do
    if exists "$name"; then say "current        container $name"; else say "would create   container $name"; CHECK_STALE=true; fi
  done
  use_ct "$panel"
  pel_piece panel-release "$PANEL_VERSION" "Panel" /opt/pelican-panel/artisan || true
  piece panel-base "$PACKAGES_PIN" "Panel web server and PHP packages" || true
  use_ct "$wings"
  pel_piece wings-release "$WINGS_VERSION" "Wings" /usr/local/bin/wings || true
  check_done
fi

[ "$(uname -m)" = x86_64 ] || fail "$(t 'The pinned Wings binary is for x86_64; this machine is %s.' "$(uname -m)")"
mkdir -p "$cache"

# ── Containers ──
use_ct "$panel"
panel_existed=$existed   # before it is created: a first install asks its questions at the end
ensure_container "$panel" 2048
use_ct "$wings"
ensure_container "$wings" 8192 --docker
bash "$scripts/mac.sh" "$panel" "$wings"

# ── Wings: room for the game servers, then its address ──
step "Wings"
size=$(incus config device get "$wings" root size 2>/dev/null || true)
if [ "${size%GiB}" -ge 100 ] 2>/dev/null; then
  ok "$(t 'Its disk is %s already' "$size")"
else
  # the root disk comes from the profile on a fresh container, then it has to be overridden
  incus config device override "$wings" root size=100GiB >/dev/null 2>&1 || incus config device set "$wings" root size=100GiB
  ok "$(t "Disk of '%s' set to 100 GB (game servers and their Docker images live there)" "$wings")"
fi
ip=$(address "$wings")
fixed_address "$wings" 30 39
wings_ip=$ip

step "Backups"
if [ "$(incus query "/1.0/instances/$wings" | jq -r '[.expanded_devices[] | select(.path == "/var/lib/pelican/backups")] | length')" != 0 ]; then
  ok "The backup folder is mounted already"
elif [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE)"
else
  spin "Creating /bulk/sensitive/pelican-backups and mounting it at /var/lib/pelican/backups" \
    bash "$scripts/manage-ct.sh" "$wings" --add-storage sensitive pelican-backups /var/lib/pelican/backups
fi

step "Wine sync device"
# /dev/ntsync is Wine's kernel thread synchronisation (Windows game servers such as Enshrouded run much
# smoother with it). The module is loaded at boot by configuration.nix; this covers a server not rebuilt yet.
[ -e /dev/ntsync ] || modprobe ntsync 2>/dev/null || true
if [ ! -e /dev/ntsync ]; then
  warn "The server has no /dev/ntsync. Run  hs rebuild  (it loads the module), then  hs recipe pelican  again. Windows game servers still run without it, only slower."
elif incus config device get "$wings" ntsync type >/dev/null 2>&1; then
  ok "/dev/ntsync is passed in already"
else
  # a unix-char device is added to a running container without a restart
  incus config device add "$wings" ntsync unix-char source=/dev/ntsync path=/dev/ntsync mode=0666 >/dev/null
  ok "$(t "/dev/ntsync is passed into '%s'" "$wings")"
fi

# ── Wings: Docker, its unit, the binary ──
wait_internet "$wings"
if adopted wings-release /usr/local/bin/wings && [ -z "$(stamp_get wings-release)" ]; then
  stamp_set wings-release adopted
  ok "$(t "Wings in '%s' was installed before: keeping it as it is" "$wings")"
fi
if [ "$(stamp_get wings-release)" != adopted ]; then
  install_docker
  step "Wings program"
  in_ct "Creating the folders of Wings" 'install -d /etc/pelican /var/lib/pelican/volumes /var/log/pelican /tmp/pelican'
  ensure_file /etc/systemd/system/wings.service "wings.service" <<'UNIT'
[Unit]
Description=Pelican Wings daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
fi
step "Wings release"
if pel_piece wings-release "$WINGS_VERSION" "Wings" /usr/local/bin/wings; then
  ok "$(t 'Wings is current (%s)' "$(stamp_get wings-release)")"
else
  find "$cache" -name 'wings-*' ! -name "wings-$WINGS_VERSION" -delete 2>/dev/null || true
  fetch_pinned wings-download "$WINGS_URL" "$WINGS_SHA256" "$cache/wings-$WINGS_VERSION" "$WINGS_VERSION"
  incus file push --mode 0755 "$cache/wings-$WINGS_VERSION" "$wings/usr/local/bin/wings.new" >/dev/null
  in_ct "Installing Wings $WINGS_VERSION" '
    mv /usr/local/bin/wings.new /usr/local/bin/wings
    systemctl daemon-reload
    systemctl enable wings >/dev/null 2>&1
    if [ -s /etc/pelican/config.yml ]; then systemctl restart wings; fi'
  piece_done wings-release "$WINGS_VERSION"
  if incus exec "$wings" -- test -s /etc/pelican/config.yml </dev/null; then
    ok "$(t 'Wings %s runs' "$WINGS_VERSION")"
  else
    note "$(t 'Wings starts as soon as the Panel has given it its configuration (see below).')"
  fi
fi

# ── Panel ──
use_ct "$panel"
wait_internet "$panel"
step "Panel"
ip=$(address "$panel")
fixed_address "$panel" 30 39
panel_ip=$ip
env=/opt/pelican-panel/.env
if adopted panel-release /opt/pelican-panel/artisan && [ -z "$(stamp_get panel-release)" ]; then
  stamp_set panel-release adopted
  ok "$(t "The Panel in '%s' was installed before: keeping it as it is" "$panel")"
fi

if [ "$(stamp_get panel-release)" != adopted ]; then
  # Debian 13 ships PHP 8.4 (Pelican wants 8.2 or newer) and Composer; sqlite for the database, mysql for whoever switches later
  if ! piece panel-base "$PACKAGES_PIN" "Panel web server and PHP packages"; then
    in_ct "Installing nginx, PHP and Composer" '
      $1 update -qq
      $1 install -y -qq nginx php-fpm php-cli php-gd php-mysql php-sqlite3 php-mbstring php-bcmath php-xml php-curl php-zip php-intl composer unzip tar curl ca-certificates' "$apt_quick"
    piece_done panel-base "$PACKAGES_PIN"
  else
    ok "The web server and PHP packages are in place"
  fi
  sock=$(incus exec "$panel" -- sh -c 'ls /run/php/php*-fpm.sock 2>/dev/null | head -n1' </dev/null || true)
  sock=${sock:-/run/php/php-fpm.sock}
  sed "s|@SOCK@|$sock|" <<'SITE' | ensure_file /etc/nginx/sites-available/pelican.conf "nginx site"
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /opt/pelican-panel/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:@SOCK@;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
SITE
  ensure_file /etc/systemd/system/pelican-queue.service "queue worker unit" <<'UNIT'
[Unit]
Description=Pelican Queue Worker
After=nginx.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /opt/pelican-panel/artisan queue:work --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  ensure_file /etc/systemd/system/pelican-schedule.service "scheduler unit" <<'UNIT'
[Unit]
Description=Pelican scheduler (artisan schedule:run)

[Service]
Type=oneshot
User=www-data
Group=www-data
# only once the Panel's installer has made the key; before that this run is skipped without an error
ExecCondition=/bin/grep -q '^APP_KEY=.' /opt/pelican-panel/.env
ExecStart=/usr/bin/php /opt/pelican-panel/artisan schedule:run
UNIT
  ensure_file /etc/systemd/system/pelican-schedule.timer "scheduler timer" <<'UNIT'
[Unit]
Description=Pelican scheduler, every minute

[Timer]
OnCalendar=minutely
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
  in_ct "Enabling the web server, the scheduler and the queue worker" '
    ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
    rm -f /etc/nginx/sites-enabled/default
    nginx -t >/dev/null 2>&1
    systemctl daemon-reload
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl reload nginx
    systemctl enable --now pelican-schedule.timer >/dev/null 2>&1
    systemctl enable pelican-queue >/dev/null 2>&1
    if grep -q "^APP_KEY=." /opt/pelican-panel/.env 2>/dev/null; then systemctl start pelican-queue; fi'
fi

step "Panel release"
if pel_piece panel-release "$PANEL_VERSION" "Panel" /opt/pelican-panel/artisan; then
  ok "$(t 'Panel is current (%s)' "$(stamp_get panel-release)")"
else
  find "$cache" -name 'panel-*' ! -name "panel-$PANEL_VERSION.tar.gz" -delete 2>/dev/null || true
  fetch_pinned panel-download "$PANEL_URL" "$PANEL_SHA256" "$cache/panel-$PANEL_VERSION.tar.gz" "$PANEL_VERSION"
  incus file push "$cache/panel-$PANEL_VERSION.tar.gz" "$panel/root/panel.tar.gz" >/dev/null
  # as the web server's user: files root creates in its cache cause error 500. An installed Panel (it has a key) is migrated, a new
  # one is finished in the browser (/installer)
  in_ct "Installing the Panel $PANEL_VERSION" '
    install -d -o www-data -g www-data /opt/pelican-panel /var/cache/pelican-composer
    cd /opt/pelican-panel
    tar -xzf /root/panel.tar.gz
    [ -f .env ] || cp .env.example .env
    chown -R www-data:www-data /opt/pelican-panel
    chmod -R 755 storage bootstrap/cache
    runuser -u www-data -- env COMPOSER_HOME=/var/cache/pelican-composer composer install --no-dev --optimize-autoloader --no-interaction --no-progress
    if grep -q "^APP_KEY=." .env; then
      runuser -u www-data -- php artisan migrate --seed --force
      runuser -u www-data -- php artisan optimize:clear
      systemctl restart pelican-queue 2>/dev/null || true
    fi
    rm -f /root/panel.tar.gz'
  piece_done panel-release "$PANEL_VERSION"
fi

url=$(incus exec "$panel" -- sed -n 's/^APP_URL=//p' "$env" </dev/null 2>/dev/null | tr -d '"' | head -n1)
case "$url" in
  https://*) ok "$(t 'The Panel has a public address already (%s), keeping it' "$url")" ;;
  "http://$panel_ip") ok "$(t 'APP_URL is http://%s already' "$panel_ip")" ;;
  *)
    # a fresh .env knows no address; with a wrong one the pages load without their design
    in_ct "$(t 'Setting APP_URL to http://%s' "$panel_ip")" '
      sed -i -E "s|^APP_URL=.*|APP_URL=http://$1|" /opt/pelican-panel/.env
      # as the web server'"'"'s user: files root creates in its cache cause error 500
      cd /opt/pelican-panel && runuser -u www-data -- php artisan optimize:clear' "$panel_ip" ;;
esac
spin "Waiting for the Panel to answer" bash -c 'for _ in $(seq 1 30); do [ "$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://$1/" 2>/dev/null)" != 000 ] && exit 0; sleep 2; done; exit 1' _ "$panel_ip" ||
  warn "$(t 'The Panel does not answer at http://%s yet. Look at: incus exec %s -- systemctl status nginx php*-fpm' "$panel_ip" "$panel")"

use_ct "$panel"
existed=$panel_existed
declare_service pelican-panel Pelican mdi-gamepad-variant private-ok Games "Game servers" 80

zoraxy=$(address zoraxy 2>/dev/null || true)
box <<DONE
$(say 'Done. The rest happens in the browser (guide "Pelican Panel und Wings", steps 2 to 4):')
$(t '  1. Panel:  http://%s/installer' "$panel_ip")
$(say "     Database: SQLite. At the end you create your admin account. Switch on")
$(say "     two-factor login in your profile. Then run  hs recipe pelican  once more:")
$(say "     it starts the queue worker, which needs the key the installer made.")
$(t '  2. Public addresses, each as a rule in Zoraxy%s:' "${zoraxy:+ (http://$zoraxy:8000)}")
$(t '       panel.<your domain>  ->  %s:80' "$panel_ip")
$(say "       (or answer yes to \"Make 'Pelican' public?\": hs recipe pelican --ask)")
$(t '       wings.<your domain>  ->  %s:8080, with the two extra response headers from the guide' "$wings_ip")
$(t "     Then in the Panel's .env:  APP_URL=https://panel.<your domain>  and  TRUSTED_PROXIES=%s" "${zoraxy:-$(_tr '<address of zoraxy>')}")
$(t '     (incus exec %s -- nano %s, afterwards run this recipe again: it leaves a public address alone).' "$panel" "$env")
$(say "  3. In the Panel: Nodes -> Create. Address wings.<your domain>, port 443, behind a proxy.")
$(t '     Copy the configuration it shows into Wings:  incus exec %s -- nano /etc/pelican/config.yml' "$wings")
$(t '     then:  incus exec %s -- systemctl restart wings' "$wings")
$(t '  4. Allocations (ports of the game servers) use the address 0.0.0.0, not %s.' "$wings_ip")
$(say "Backups of the game servers land in /bulk/sensitive/pelican-backups.")
$(docs_hint pelican)
DONE
