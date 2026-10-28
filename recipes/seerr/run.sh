#!/usr/bin/env bash
# recipe: Seerr: a page where family and friends ask for films and series (works with Jellyfin and Plex)
# recipe.de: Seerr: eine Seite, auf der Familie und Freunde Filme und Serien wünschen können (läuft mit Jellyfin und Plex)
# kind: generic
# needs: docker
# uses: -
set -euo pipefail

# What it does: creates the container "seerr" with Docker inside and runs Seerr (the merged successor of
# Jellyseerr and Overseerr, ghcr.io/seerr-team/seerr). A request goes to Radarr or Sonarr (recipe "arr"), which
# find and load it; Seerr shows what is available in Jellyfin (or Plex, later). People sign in with their
# Jellyfin account, so there is no second set of passwords.
#   config    /opt/seerr/config (SSD pool); `hs backup ct seerr on` is switched on and a dump of its database
#             is written right before each backup (/usr/local/sbin/hs-seerr-dump)
# No share is mounted: Seerr never touches a file of the library.
# Zoraxy: this is the one page of the film apps that can be shown to friends (a rule for it is YOUR decision,
# see the guide); the setup wizard is open to whoever reaches it first, so finish it before any rule exists.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-seerr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  say "  start Seerr (asks for the port, default 80)"
  say "  put the container in the nightly backup with a database dump"
  exit 0
fi

port_setting "Seerr" 5055
ensure_container "$ct" 1024 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
install_docker

step "Seerr"
# docker-compose.yml is written again at every run; Seerr's data stays in /opt/seerr/config. The image runs as
# user 1000 and needs "init: true" (it has no init process of its own).
compose='mkdir -p /opt/seerr/config
  cat > /opt/seerr/docker-compose.yml.new <<YML
services:
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    init: true
    restart: unless-stopped
    user: "1000:1000"
    ports: ["$2:5055"]
    environment:
      - TZ=$1
      - LOG_LEVEL=info
    volumes: ["/opt/seerr/config:/app/config"]
YML
  mv /opt/seerr/docker-compose.yml.new /opt/seerr/docker-compose.yml
  chown -R 1000:1000 /opt/seerr/config
  cd /opt/seerr && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings (port)" "$compose" "$tz" "$PORT"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Seerr not started"
else
  in_ct "Downloading Seerr" 'cd /opt/seerr && docker compose pull -q'
  in_ct "Starting Seerr" 'cd /opt/seerr && docker compose up -d --remove-orphans'
  wait_page Seerr 'docker compose -f /opt/seerr/docker-compose.yml logs --tail 50'
fi

step "Backup"
in_ct "Installing the dump tool" '$1 update -qq && $1 install -y -qq sqlite3' "$apt_quick"
in_ct "Writing the dump command" 'cat > /usr/local/sbin/hs-seerr-dump <<"SH"
#!/bin/sh
# safe copy of Seerr database into /opt/seerr/_dump (runs right before the backup)
set -eu
rm -rf /opt/seerr/_dump; mkdir -p /opt/seerr/_dump
for f in /opt/seerr/config/db/*.sqlite3; do
  [ -f "$f" ] && sqlite3 "$f" ".backup /opt/seerr/_dump/$(basename "$f")"
done
exit 0
SH
  chmod 755 /usr/local/sbin/hs-seerr-dump'
media_backup /usr/local/sbin/hs-seerr-dump
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

declare_service seerr Seerr seerr private-ok Apps "Requests for films and series"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  Finish the setup wizard first (it is open to whoever gets there first): sign in with your Jellyfin")
$(say "  account, then add Radarr (http://<arr address>:7878) and Sonarr (:8989) with their API keys.")
$(say "  No Zoraxy rule yet: whether friends reach it from outside is described in the guide.")
$(docs_hint arr)
DONE
