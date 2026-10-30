#!/usr/bin/env bash
# recipe: Maintainerr: cleans up unwatched films and series by rules you write (it has none at first, deletes nothing)
# recipe.de: Maintainerr: räumt nicht angesehene Filme und Serien nach deinen eigenen Regeln auf (hat zuerst keine, löscht nichts)
# kind: generic
# needs: docker
# uses: -
set -euo pipefail

# What it does: creates the container "maintainerr" with Docker inside and runs Maintainerr (6246, its makers' image):
# rules YOU write (watched by nobody for a year, ...) collect films and series and, only when you switch it on, delete
# them through Radarr and Sonarr. It starts with no rules. The other apps of the group are recipes of their own
# (radarr, sonarr, lidarr, prowlarr, bazarr); the guide is the one of the recipe radarr.
#   config    /opt/maintainerr/data inside the container (SSD pool); `hs backup ct maintainerr on` is switched on and a
#             dump of the database is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/maintainerr)
# No share is mounted: Maintainerr deletes through Radarr and Sonarr, never by itself.
# No Zoraxy rule: Maintainerr is an admin page for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-maintainerr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=6246   # Maintainerr's own port

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  say "  start Maintainerr (port 6246), with no rules: it deletes nothing until you write one"
  say "  put the container in the nightly backup with a database dump"
  exit 0
fi

ensure_container "$ct" 1024 --docker
fixed_address "$ct" 50 99
wait_internet "$ct"
install_docker

step "Maintainerr"
# docker-compose.yml is written again at every run; Maintainerr's own data stays in /opt/maintainerr/data
compose='mkdir -p /opt/maintainerr/data
  cat > /opt/maintainerr/docker-compose.yml.new <<YML
services:
  maintainerr:
    image: ghcr.io/maintainerr/maintainerr:latest
    container_name: maintainerr
    user: "1000:1000"
    restart: unless-stopped
    ports: ["6246:6246"]
    environment:
      - TZ=$1
    volumes: ["/opt/maintainerr/data:/opt/data"]
YML
  mv /opt/maintainerr/docker-compose.yml.new /opt/maintainerr/docker-compose.yml
  chown -R 1000:1000 /opt/maintainerr
  cd /opt/maintainerr && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings" "$compose" "$tz"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Maintainerr not started"
else
  in_ct "Downloading Maintainerr" 'cd /opt/maintainerr && docker compose pull -q'
  in_ct "Starting Maintainerr" 'cd /opt/maintainerr && docker compose up -d --remove-orphans'
  wait_page Maintainerr "docker compose -f /opt/maintainerr/docker-compose.yml logs --tail 50"
fi

step "Backup"
# Maintainerr keeps a SQLite database, which must not be copied while it is written. The dump goes to /var/backups/hs/maintainerr.
install_dump_tool sqlite
media_backup "/usr/local/sbin/hs-dump sqlite-tree maintainerr /opt/maintainerr"
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

declare_service maintainerr Maintainerr maintainerr never-public Media "Cleans up unwatched media by your own rules"

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings: connect Jellyfin (or Plex), Radarr and Sonarr (addresses and API keys), Seerr if you have it")
$(say "2. Rules: make a rule as a collection first, look at what it would hit, only then switch deleting on")
$(docs_hint radarr)
DONE
