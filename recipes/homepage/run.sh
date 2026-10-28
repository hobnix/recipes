#!/usr/bin/env bash
# recipe: Homepage, a start page with a link to every admin page and every container on this server
# recipe.de: Homepage, eine Startseite mit Links zu jeder Verwaltungsseite und jedem Container dieses Servers
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container (Debian 13), installs Node.js and pnpm in it and builds the pinned Homepage release
# (gethomepage/homepage, checksum-checked) unless that version is installed already. A Homepage installed earlier by another
# installer is adopted: its config and .env stay, only a different version is replaced. Then it writes the list of links from
# what is actually running: the server's own pages, and for every instance the first port that answers a browser. Run it again
# after adding containers; the list is rebuilt. `hs recipe homepage --check` says what a run would update, and changes nothing.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# The pins. The release is a GitHub tag archive: GitHub publishes no checksum for it, so this one was computed when the pin was
# chosen (sha256 of the .tar.gz). A new version = a new version AND a new checksum here.
HOMEPAGE_VERSION=2.7.0
HOMEPAGE_SHA256=53c6a72da2242d81233248d04f777425da37560f6fc3a37d6cab387b3d61b5f4
PNPM_VERSION=10.18.0
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
ct=${RECIPE_NAME:-homepage}
target=/opt/homepage/config/services.yaml
marker="# Written by \"hs recipe homepage\". Run it again to refresh; edits here are overwritten."

dry=false
[ "${1:-}" = --dry-run ] && dry=true
. "$scripts/lib/ui.sh"
. "$scripts/lib/machine.sh"
. "$scripts/lib/dc.sh"
. "$scripts/lib/setting.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"   # setting/port_setting, low_ports

# ":<port>" a recipe was told to use for an instance (nothing for 80), else the usual one
port_of() {   # port_of <name> <usual port>
  local p
  p=$(sed -n 's/^PORT=//p' "${HS_STATE_DIR:-/var/lib/hs}/recipe-$1.conf" 2>/dev/null | tail -n1 || true)
  p=${p:-$2}
  [ "$p" = 80 ] || printf ':%s' "$p"
}

# Pages of known instances that are not at "/" of the first open port
known() {   # known <name> <ip>  ->  "url<TAB>description<TAB>icon" or nothing
  case "$1" in
    zoraxy)        printf 'http://%s%s\tReverse proxy: which address goes where\tmdi-shuffle-variant\n' "$2" "$(port_of zoraxy 8000)" ;;
    monitoring)    printf 'http://%s%s\tHistory: load, disks, containers\tmdi-chart-line\n' "$2" "$(port_of monitoring 3000)" ;;
    jellyfin)      printf 'http://%s%s\tFilms, series, music\tmdi-movie-open\n' "$2" "$(port_of jellyfin 8096)" ;;
    immich)        printf 'http://%s%s\tPhotos and videos\tmdi-image-multiple\n' "$2" "$(port_of immich 2283)" ;;
    tdarr)         printf 'http://%s%s\tConvert films for Jellyfin\tmdi-movie-roll\n' "$2" "$(port_of tdarr 8265)" ;;
    uptime-kuma)   printf 'http://%s%s\tService checks\tmdi-heart-pulse\n' "$2" "$(port_of uptime-kuma 3001)" ;;
    docker)        printf 'http://%s\tDocker stacks\tmdi-docker\n' "$2" ;;
    pelican-panel) printf 'http://%s\tGame servers\tmdi-gamepad-variant\n' "$2" ;;
    docs)          printf 'http://%s%s\tGuides and commands\tmdi-book-open-variant\n' "$2" "$(port_of docs 80)" ;;
    authentik)     printf 'http://%s%s/if/admin/\tLogin: users, groups, applications\tmdi-shield-account\n' "$2" "$(port_of authentik 9000)" ;;
    bulwark)       printf 'http://%s\tWebmail\tmdi-email-outline\n' "$2" ;;
    stalwart)      printf 'https://%s\tMail server (admin)\tmdi-email-lock\n' "$2" ;;
    synapse)       printf 'http://%s\tMatrix chat server\tmdi-forum-outline\n' "$2" ;;
    ntfy)          printf 'http://%s\tPush messages\tmdi-bell\n' "$2" ;;
    *) return 1 ;;
  esac
}

# Where and under which name an instance shows up on the page
group_of() {   # group_of <name>
  case "$1" in
    zoraxy|docker|authentik|docs|tdarr) echo Administration ;;
    jellyfin|immich|bulwark|stalwart|synapse) echo Apps ;;
    monitoring|uptime-kuma) echo Monitoring ;;
    pelican-panel) echo Games ;;
    *) echo Other ;;
  esac
}
label_of() {   # label_of <name>
  case "$1" in
    docker) echo Arcane ;; monitoring) echo Grafana ;; pelican-panel) echo Pelican ;; uptime-kuma) echo "Uptime Kuma" ;;
    zoraxy) echo Zoraxy ;; authentik) echo Authentik ;; docs) echo Docs ;; bulwark) echo Webmail ;; stalwart) echo "Mail server" ;;
    synapse) echo Matrix ;; jellyfin) echo Jellyfin ;; immich) echo Immich ;; tdarr) echo Tdarr ;; *) echo "$1" ;;
  esac
}

# The first port of an instance that answers HTTP. Database, mail, file
# sharing and login ports are never web pages and are skipped.
web_url() {   # web_url <name> <ip>
  local ports p scheme
  ports=$(incus exec "$1" -- ss -ltnH 2>/dev/null </dev/null | awk '{ n = split($4, a, ":"); print a[n] }' | sort -un |
    grep -vxE '22|25|53|88|111|135|139|389|445|464|636|2049|3268|3269|3306|5432|6379|2022|8080' || true)
  # prefer the usual web ports
  for p in 80 443 3000 8000 8096 8443 $ports; do
    grep -qx "$p" <<<"$ports" || continue
    scheme=http; case "$p" in 443|8443) scheme=https ;; esac
    if [ "$(curl -sk -m 2 -o /dev/null -w '%{http_code}' "$scheme://$2:$p/")" != 000 ]; then
      case "$p" in 80|443) echo "$scheme://$2" ;; *) echo "$scheme://$2:$p" ;; esac
      return 0
    fi
  done
  return 1
}

# The page lives in groups: Administration, Apps, Monitoring, Games, Other, Public.
# A link uses the name <instance>.<siteName>.<adDomain> (hs dns sync) when the domain controller knows it
# (same address), else the address. Only devices that use the domain controller for
# DNS (the PC, or Tailscale with split DNS) can open the names. Public = the hosts of the Zoraxy rules
# (not the apex, root, wings and docker: those are an API and a webhook);
# names in /var/lib/hs/homepage-hide (one per line) are left out as well.
generate() {
  local host name type ip line url desc icon grp label domain dns_ip sh
  local -A entries=()
  local site claimed
  # the containers whose services say what their tile is (hs services declare): their tile comes from the service, not from the table below
  claimed=$(bash "$scripts/services.sh" tiles --containers 2>/dev/null || true)
  site=$(tr -d ' 
' <"${HS_SITE_NAME_FILE:-/etc/hs/site-name}" 2>/dev/null | tr 'A-Z' 'a-z' || true)
  local order=(Administration Apps Monitoring Games Other Public)
  # adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }
  domain=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' || true)
  host=$(ip -4 -o addr show br0 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
  host=${host:-$(hostname -I | awk '{ print $1 }')}

  # use the name instead of the address when the domain knows it for this very address
  named() {   # named <instance-name> <ip> <url>  ->  url
    local n=$1 a=$2 u=$3 got
    if [ -n "$domain" ] && [ -n "$site" ]; then
      # the host itself does not ask the domain controller, so ask that (hs dns sync makes these names)
      got=$(incus exec "$(dc_name)" -- getent hosts "$n.$site.$domain" 2>/dev/null </dev/null | awk '{ print $1; exit }' || true)
      [ "$got" = "$a" ] && u=${u/$a/$n.$site.$domain}
    fi
    printf '%s' "$u"
  }
  add() {   # add <group> <label> <href> <description> <icon>
    entries[$1]+=$(printf '    - %s:\n        href: %s\n        description: "%s"\n        icon: %s\n' "$2" "$3" "$4" "$5")$'\n'
  }

  if [ "$(cat /etc/hs/incus-ui 2>/dev/null || echo on)" = on ]; then
    add Administration Incus "$(named incus "$host" "https://$host:8443/ui/")" "Containers and VMs" mdi-cube-outline
  fi
  while IFS=$'\t' read -r name type ip; do
    [ "$name" != "$ct" ] && [ "$ip" != - ] || continue
    ! grep -qxF "$name" <<<"$claimed" || continue
    if [ "$name" = arr ]; then
      # one tile per app: the name <app>.<site>.<domain> when hs dns sync made it (the container's port 80 routes by name), else address:port
      local app port adesc aicon n nurl
      for app in "Radarr 7878 Films mdi-filmstrip" "Sonarr 8989 Series mdi-television-classic" "Lidarr 8686 Music mdi-music" "Prowlarr 9696 Indexers mdi-magnify" \
                 "Bazarr 6767 Subtitles mdi-subtitles-outline" "Maintainerr 6246 Clean-up_rules mdi-broom"; do
        set -- $app; label=$1; port=$2; adesc=${3//_/ }; aicon=$4
        curl -s -m 2 -o /dev/null "http://$ip:$port/" || continue   # not installed (Maintainerr is optional)
        n=$(tr 'A-Z' 'a-z' <<<"$label")
        nurl=$(named "$n" "$ip" "http://$ip/")   # a name changes the url, otherwise it stays the address
        [ "$nurl" != "http://$ip/" ] || nurl="http://$ip:$port/"
        add Apps "$label" "$nurl" "$adesc" "$aicon"
      done
      continue
    fi
    if line=$(known "$name" "$ip"); then
      IFS=$'\t' read -r url desc icon <<<"$line"
    elif url=$(web_url "$name" "$ip"); then
      desc=$([ "$type" = vm ] && echo "Virtual machine" || echo "Container"); icon=mdi-application
    else
      continue   # nothing to open in a browser (e.g. a tunnel, a domain controller or Wings)
    fi
    add "$(group_of "$name")" "$(label_of "$name")" "$(named "$name" "$ip" "$url")" "$desc" "$icon"
  done < <(bash "$scripts/manage-ct.sh" --list | awk -F'\t' '$3 == "Running" { print $1 "\t" $2 "\t" $4 }')

  # the public addresses (Zoraxy rules)
  if incus info zoraxy >/dev/null 2>&1; then
    while IFS= read -r sh; do
      [ -n "$sh" ] && [ "$sh" != root ] || continue
      case "$sh" in wings.*|docker.*) continue ;; esac
      case "$sh" in *.*.*) ;; *) continue ;; esac   # the apex itself has one dot
      grep -qxF "$sh" "${HS_STATE_DIR:-/var/lib/hs}/homepage-hide" 2>/dev/null && continue
      add Public "${sh%%.*}" "https://$sh" "On the internet" mdi-web
    done < <(incus exec zoraxy -- sh -c 'ls /opt/zoraxy/conf/proxy 2>/dev/null' </dev/null | sed -n 's/\.config$//p' | sort)
  fi

  # the tiles of the services that want one (group, title, link, description, icon)
  local tgrp ttitle thref tdesc ticon g
  while IFS=$'\t' read -r tgrp ttitle thref tdesc ticon _; do
    [ -n "$ttitle" ] || continue
    [ "$tdesc" != - ] || tdesc=""   # "-" = no description (an empty field would be skipped by read and shift the icon into the description)
    add "${tgrp:-Apps}" "$ttitle" "$thref" "$tdesc" "${ticon:-mdi-application}"
  done < <(bash "$scripts/services.sh" tiles 2>/dev/null || true)
  # a group a service names that is not in the list above comes last
  for g in "${!entries[@]}"; do
    case " ${order[*]} " in *" $g "*) ;; *) order+=("$g") ;; esac
  done

  echo "$marker"
  for grp in "${order[@]}"; do
    [ -n "${entries[$grp]:-}" ] || continue
    echo
    echo "- $grp:"
    printf '%s' "${entries[$grp]}"
  done
}

# An installation made by another installer is adopted: its version becomes the stamp (so it is not rebuilt for nothing)
adopt_homepage() {
  [ -z "$(stamp_get homepage-release)" ] || return 0
  incus info "$ct" >/dev/null 2>&1 || return 0
  local v
  v=$(incus exec "$ct" -- sed -n '/^ *"version":/{s/^ *"version": *"\([^"]*\)".*/\1/p;q}' /opt/homepage/package.json </dev/null 2>/dev/null || true)
  if [ -n "$v" ] && incus exec "$ct" -- test -f /etc/systemd/system/homepage.service </dev/null 2>/dev/null; then
    stamp_set homepage-release "$v"
    ! $CHECK || return 0
    note "$(t 'Homepage %s is installed already, keeping its config' "$v")"
  fi
}

# Build the pinned release in /opt/homepage.new, keep config and .env of the old one, swap, start; back to the old one if it does not run
install_homepage() {
  local tgz=$state/cache/homepage-$HOMEPAGE_VERSION.tar.gz
  mkdir -p "$state/cache"
  fetch_pinned homepage-source "https://github.com/gethomepage/homepage/archive/refs/tags/v$HOMEPAGE_VERSION.tar.gz" "$HOMEPAGE_SHA256" "$tgz" "$HOMEPAGE_VERSION"
  wait_internet "$ct"
  incus file push "$tgz" "$ct/tmp/homepage.tar.gz" >/dev/null
  in_ct "$(t 'Installing Node.js and pnpm')" '
    apt-get update -qq
    apt-get install -y -qq nodejs npm ca-certificates curl >/dev/null
    node -e "process.exit(+process.versions.node.split(\".\")[0] >= 20 ? 0 : 1)" || { echo "Node.js 20 or newer is needed" >&2; exit 1; }
    npm install -g --silent "pnpm@$1"' "$PNPM_VERSION"
  in_ct "$(t 'Building Homepage %s (a few minutes)' "$HOMEPAGE_VERSION")" '
    rm -rf /opt/homepage.new; mkdir -p /opt/homepage.new
    tar xzf /tmp/homepage.tar.gz -C /opt/homepage.new --strip-components=1
    cd /opt/homepage.new
    mkdir -p config
    if [ -d /opt/homepage/config ]; then cp -a /opt/homepage/config/. config/; fi
    if [ -f /opt/homepage/.env ]; then cp -a /opt/homepage/.env .env; fi
    export NEXT_TELEMETRY_DISABLED=1 NODE_OPTIONS=--max-old-space-size=1536
    pnpm install --frozen-lockfile --silent
    NEXT_PUBLIC_VERSION="v$1" pnpm run build >/dev/null' "$HOMEPAGE_VERSION"
  in_ct "$(t 'Starting Homepage %s' "$HOMEPAGE_VERSION")" '
    systemctl stop homepage 2>/dev/null || true
    rm -rf /opt/homepage.old
    if [ -d /opt/homepage ]; then mv /opt/homepage /opt/homepage.old; fi
    mv /opt/homepage.new /opt/homepage
    cat > /etc/systemd/system/homepage.service <<UNIT
[Unit]
Description=Homepage
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/homepage
EnvironmentFile=-/opt/homepage/.env
Environment=NODE_ENV=production
Environment=PORT=3000
ExecStart=/usr/bin/node /opt/homepage/node_modules/next/dist/bin/next start
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload; systemctl enable homepage >/dev/null 2>&1; systemctl restart homepage
    sleep 5
    if ! systemctl is-active --quiet homepage; then
      systemctl stop homepage || true
      rm -rf /opt/homepage.failed; mv /opt/homepage /opt/homepage.failed
      if [ -d /opt/homepage.old ]; then mv /opt/homepage.old /opt/homepage; systemctl restart homepage || true; fi
      echo "Homepage did not start; the new build is in /opt/homepage.failed (journalctl -u homepage)" >&2
      exit 1
    fi
    rm -rf /opt/homepage.old /tmp/homepage.tar.gz'
  piece_done homepage-release "$HOMEPAGE_VERSION"
  ok "$(t 'Homepage %s is installed' "$HOMEPAGE_VERSION")"
}

if $dry; then
  adopt_homepage
  if ! piece homepage-release "$HOMEPAGE_VERSION" "Homepage release"; then
    printf '%s
' "$(t "Would download Homepage %s (github.com/gethomepage/homepage, checked against a pinned checksum), install Node.js and pnpm in '%s' and build it." "$HOMEPAGE_VERSION" "$ct")" >&2
  fi
  printf '%s\n' "$(t "Would write this to %s in '%s':" "$target" "$ct")" >&2
  generate
  exit 0
fi

# --refresh (hs services apply): only the links again, no set-up, no questions
if [ "${1:-}" = --refresh ]; then
  incus info "$ct" >/dev/null 2>&1 || { echo "Homepage is not installed ('$ct')" >&2; exit 1; }
  new=$(generate)
  printf '%s\n' "$new" | incus exec "$ct" -- tee "$target" >/dev/null
  echo "$(grep -c 'href:' <<<"$new") links"
  exit 0
fi

# --check: what a run would update, nothing is changed
if $CHECK; then
  adopt_homepage
  piece homepage-release "$HOMEPAGE_VERSION" "Homepage release" || true
  if $existed; then
    generate | ensure_file "$target" "Links file"
    if incus exec "$ct" -- grep -q '^layout:' /opt/homepage/config/settings.yaml </dev/null 2>/dev/null; then
      say "current        Layout"
    else
      CHECK_STALE=true; say "would update   Layout (not written yet)"
    fi
  else
    CHECK_STALE=true; say "would update   Links file (new container)"; say "would update   Layout (new container)"
  fi
  check_done
fi

ensure_container "$ct" 2048   # the build needs more than the app does; the limit is only an upper bound
$existed || bash "$scripts/mac.sh" "$ct"
adopt_homepage
step "Homepage"
if piece homepage-release "$HOMEPAGE_VERSION" "Homepage release"; then
  ok "$(t 'Homepage %s is installed already' "$HOMEPAGE_VERSION")"
else
  install_homepage
fi

# The port lives in a systemd drop-in (Environment=PORT=..., it wins over .env); the recipe
# sets 80 there. Without that line Homepage listens on 3000.
dropin=/etc/systemd/system/homepage.service.d/override.conf
legacy=$(incus exec "$ct" -- sed -n 's/^Environment=PORT=//p' "$dropin" </dev/null 2>/dev/null | tail -n1 || true)
legacy=${legacy:-3000}
port_setting "Homepage" "$legacy" 80

step "Port"
if [ "$legacy" != "$PORT" ]; then
  low_ports
  in_ct "$(t 'Setting the port of the web page to %s' "$PORT")" '
    mkdir -p "$(dirname "$2")"
    { grep -v "^Environment=PORT=" "$2" 2>/dev/null || true; } > "$2.new"
    grep -q "^\[Service\]" "$2.new" || echo "[Service]" >> "$2.new"
    echo "Environment=PORT=$1" >> "$2.new"; mv "$2.new" "$2"
    systemctl daemon-reload; systemctl restart homepage' "$PORT" "$dropin"
fi
ok "$(t 'The web page listens on port %s' "$PORT")"

step "Links"
new=$(generate)
# keep a copy of a list somebody wrote by hand, once
if incus exec "$ct" -- test -s "$target" && ! incus exec "$ct" -- grep -qF "hs recipe homepage" "$target"; then
  incus exec "$ct" -- cp "$target" "$target.before-recipe"
  note "$(t "Your previous list is kept as %s.before-recipe in '%s'." "$target" "$ct")"
fi
printf '%s\n' "$new" | incus exec "$ct" -- tee "$target" >/dev/null
ok "$(t '%s links written.' "$(printf '%s\n' "$new" | grep -c 'href:')")"

# the layout of the groups: columns, and Public as a grid of four (only when settings.yaml has no layout yet)
settings=/opt/homepage/config/settings.yaml
if incus exec "$ct" -- test -f "$settings" && ! incus exec "$ct" -- grep -q '^layout:' "$settings"; then
  incus exec "$ct" -- cp "$settings" "$settings.before-layout"
  incus exec "$ct" -- tee -a "$settings" >/dev/null <<'LAYOUT'

# Written by "hs recipe homepage": the groups as columns, Public as a grid of four.
layout:
  Administration:
    style: column
  Apps:
    style: column
  Monitoring:
    style: column
  Games:
    style: column
  Other:
    style: column
  Public:
    style: row
    columns: 4
LAYOUT
  ok "Layout written to settings.yaml (Public as a grid of four)"
elif incus exec "$ct" -- grep -q '^layout:' "$settings" 2>/dev/null; then
  note "settings.yaml has a layout already, leaving it alone"
fi

ip=$(bash "$scripts/manage-ct.sh" --list | awk -F'\t' -v c="$ct" '$1 == c { print $4 }')

# Homepage refuses any host name it was not told about ("Host validation failed"), so the name
# <ct>.<siteName>.<adDomain> (made by hs dns sync) is allowed next to the address. The page does not list itself.
site=$(tr -d ' \r\n' <"${HS_SITE_NAME_FILE:-/etc/hs/site-name}" 2>/dev/null | tr 'A-Z' 'a-z' || true)
realm=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' || true)
allowed="$ip,$ip:$PORT"
fullname=""
if [ -n "$site" ] && [ -n "$realm" ]; then
  fullname=$ct.$site.$realm
  allowed="$allowed,$fullname,$fullname:$PORT"
fi
envfile=/opt/homepage/.env
cur=$(incus exec "$ct" -- sed -n 's/^HOMEPAGE_ALLOWED_HOSTS=//p' "$envfile" </dev/null 2>/dev/null | tail -n1 || true)
if [ "$cur" != "$allowed" ]; then
  # also creates the file: without a domain (or a Homepage without .env) the address itself was refused ("Host validation failed")
  incus exec "$ct" -- sh -c "touch '$envfile'; grep -v '^HOMEPAGE_ALLOWED_HOSTS=' '$envfile' > '$envfile.new'; echo 'HOMEPAGE_ALLOWED_HOSTS=$allowed' >> '$envfile.new'; mv '$envfile.new' '$envfile'; systemctl restart homepage" </dev/null
  if [ -n "$fullname" ]; then ok "$(t 'The page can also be opened as http://%s' "$fullname")"; else ok "$(t 'The page can be opened at http://%s' "$ip")"; fi
fi

# the dashboard capability: services that want a tile get one (hs services apply writes the links again)
setting_set dashboard homepage || true   # not fatal: the links are written either way

step "Summary"
kv "Container" "$ct"
kv "Address" "${ip:-?}"
kv "Web page" "$(web)"
box <<DONE
$(say "Homepage reads the list on the next page load. After adding containers, run this recipe again.")
$(docs_hint containers-and-apps)
DONE
