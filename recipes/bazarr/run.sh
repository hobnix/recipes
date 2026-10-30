#!/usr/bin/env bash
# recipe: Bazarr: fetches subtitles for the films and series of Radarr and Sonarr
# recipe.de: Bazarr: holt Untertitel für die Filme und Serien von Radarr und Sonarr
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "bazarr" with Docker inside and runs Bazarr (6767, linuxserver.io image): it asks
# Radarr and Sonarr what they hold and puts the subtitles next to the video files (not for Lidarr). The other apps of
# the group are recipes of their own (radarr, sonarr, lidarr, prowlarr, maintainerr); the guide is the one of the recipe radarr.
#   share              the share "media" (the one of Jellyfin), READ-WRITE at /media with a user "bazarr" mapped 1:1:
#                      the same path Radarr and Sonarr use, so no path mapping is needed
#   config             /opt/bazarr/config inside the container (SSD pool); `hs backup ct bazarr on` is switched on and a
#                      dump of the database is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/bazarr)
# No Zoraxy rule: Bazarr is an admin page for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-bazarr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=6767   # Bazarr's own port

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media, with folders movies, series, music, downloads"
  say "  start Bazarr (port 6767)"
  say "  put the container in the nightly backup with a database dump"
  exit 0
fi

setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
ensure_container "$ct" 1024 --docker
fixed_address "$ct" 50 99
wait_internet "$ct"
media_storage bazarr
install_docker

step "Bazarr"
# docker-compose.yml is written again at every run; Bazarr's own data stays in /opt/bazarr/config
compose='mkdir -p /opt/bazarr/config
  cat > /opt/bazarr/docker-compose.yml.new <<YML
services:
  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports: ["6767:6767"]
    environment:
      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002
    volumes: ["/opt/bazarr/config:/config", "/media:/media"]
YML
  mv /opt/bazarr/docker-compose.yml.new /opt/bazarr/docker-compose.yml
  chown -R "$2:$3" /opt/bazarr
  cd /opt/bazarr && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings" "$compose" "$tz" "${ids%%:*}" "${ids##*:}"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Bazarr not started"
else
  in_ct "Downloading Bazarr" 'cd /opt/bazarr && docker compose pull -q'
  in_ct "Starting Bazarr" 'cd /opt/bazarr && docker compose up -d --remove-orphans'
  wait_page Bazarr "docker compose -f /opt/bazarr/docker-compose.yml logs --tail 50"
fi

step "Backup"
# Bazarr keeps a SQLite database, which must not be copied while it is written. The dump goes to /var/backups/hs/bazarr.
install_dump_tool sqlite
media_backup "/usr/local/sbin/hs-dump sqlite-tree bazarr /opt/bazarr"
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

declare_service bazarr Bazarr bazarr never-public Media "Subtitles for films and series"

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings -> Languages: a language profile; Settings -> Providers: a subtitle provider (an account is needed)")
$(say "2. Settings -> Radarr and Settings -> Sonarr: their addresses and API keys (no path mapping: /media is the same everywhere)")
$(docs_hint radarr)
DONE
