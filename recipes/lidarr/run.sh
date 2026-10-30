#!/usr/bin/env bash
# recipe: Lidarr: keeps your music in order: searches albums, sends the download to SABnzbd, files it in the library
# recipe.de: Lidarr: hält deine Musik in Ordnung: sucht Alben, schickt den Download an SABnzbd, legt ihn in der Bibliothek ab
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "lidarr" with Docker inside and runs Lidarr (8686, linuxserver.io image):
# music, searched, sent to SABnzbd, renamed and filed in /media/music. The other apps of the group are recipes of
# their own (radarr, sonarr, prowlarr, bazarr, maintainerr); the guide is the one of the recipe radarr.
#   share              the share "media" (the one of Jellyfin), READ-WRITE at /media with a user "lidarr" mapped 1:1,
#                      the same path SABnzbd uses: a finished download moves into the library by a hard link
#   config             /opt/lidarr/config inside the container (SSD pool); `hs backup ct lidarr on` is switched on and a
#                      dump of the databases is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/lidarr)
#   push messages      the topic of the film apps (state/media-ntfy), see the closing text
# No Zoraxy rule: Lidarr is an admin page for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-lidarr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=8686   # Lidarr's own port: Prowlarr is told this one

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media, with folders movies, series, music, downloads"
  say "  start Lidarr (port 8686)"
  say "  use the push topic of the film apps, and put the container in the nightly backup with a database dump"
  exit 0
fi

setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
ensure_container "$ct" 1024 --docker
fixed_address "$ct" 50 99
wait_internet "$ct"
media_storage lidarr
install_docker

step "Lidarr"
# docker-compose.yml is written again at every run; Lidarr's own data stays in /opt/lidarr/config
compose='mkdir -p /opt/lidarr/config
  cat > /opt/lidarr/docker-compose.yml.new <<YML
services:
  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    restart: unless-stopped
    ports: ["8686:8686"]
    environment:
      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002
    volumes: ["/opt/lidarr/config:/config", "/media:/media"]
YML
  mv /opt/lidarr/docker-compose.yml.new /opt/lidarr/docker-compose.yml
  chown -R "$2:$3" /opt/lidarr
  cd /opt/lidarr && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings" "$compose" "$tz" "${ids%%:*}" "${ids##*:}"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Lidarr not started"
else
  in_ct "Downloading Lidarr" 'cd /opt/lidarr && docker compose pull -q'
  in_ct "Starting Lidarr" 'cd /opt/lidarr && docker compose up -d --remove-orphans'
  wait_page Lidarr "docker compose -f /opt/lidarr/docker-compose.yml logs --tail 50"
fi

step "Backup"
# Lidarr keeps SQLite databases, which must not be copied while they are written. The dump goes to /var/backups/hs/lidarr.
install_dump_tool sqlite
media_backup "/usr/local/sbin/hs-dump sqlite-tree lidarr /opt/lidarr"
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

media_ntfy

declare_service lidarr Lidarr lidarr never-public Media "Music: searches, downloads and files it"

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings -> Media Management -> Root Folder:  /media/music")
$(say "2. Settings -> Download Clients -> SABnzbd (hs recipe sabnzbd), category  audio")
$(say "3. Prowlarr (hs recipe prowlarr): Settings -> Apps -> Lidarr, this address and the API key (Settings -> General)")
$(t 'Push messages (Settings -> Connect -> ntfy):  server %s   topic %s' "$ntfy_server" "$ntfy_topic")
$(docs_hint radarr)
DONE
