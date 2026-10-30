#!/usr/bin/env bash
# recipe: Sonarr: keeps your series in order: searches new episodes, sends the download to SABnzbd, files it in the library
# recipe.de: Sonarr: hält deine Serien in Ordnung: sucht neue Folgen, schickt den Download an SABnzbd, legt ihn in der Bibliothek ab
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "sonarr" with Docker inside and runs, from their makers' images:
#   Sonarr (8989)      series: searches, sends the download to SABnzbd, renames and files it in /media/series
#   Recyclarr          not running: a tool for `docker compose run`, which syncs the quality profiles of the
#                      TRaSH guides (German ones included) into Sonarr
# The other apps of the group are recipes of their own (radarr, lidarr, prowlarr, bazarr, maintainerr); the guide is the
# one of the recipe radarr.
#   share              the share "media" (the one of Jellyfin), READ-WRITE at /media with a user "sonarr" mapped 1:1,
#                      the same path SABnzbd uses: a finished download moves into the library by a hard link
#   config             /opt/sonarr/config inside the container (SSD pool); `hs backup ct sonarr on` is switched on and a
#                      dump of the databases is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/sonarr)
#   push messages      the topic of the film apps (state/media-ntfy), see the closing text
# No Zoraxy rule: Sonarr is an admin page for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-sonarr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=8989   # Sonarr's own port: Prowlarr, Seerr and Bazarr are told this one

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1536 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media, with folders movies, series, music, downloads"
  say "  start Sonarr (port 8989) and install Recyclarr as a tool"
  say "  use the push topic of the film apps, and put the container in the nightly backup with a database dump"
  exit 0
fi

setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
ensure_container "$ct" 1536 --docker
fixed_address "$ct" 50 99
wait_internet "$ct"
media_storage sonarr
install_docker

step "Sonarr"
# docker-compose.yml is written again at every run; Sonarr's own data stays in /opt/sonarr/config
compose='mkdir -p /opt/sonarr/config /opt/sonarr/recyclarr
  cat > /opt/sonarr/docker-compose.yml.new <<YML
services:
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports: ["8989:8989"]
    environment:
      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002
    volumes: ["/opt/sonarr/config:/config", "/media:/media"]
  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:8
    container_name: recyclarr
    user: "$2:$3"
    profiles: ["tools"]
    environment:
      - TZ=$1
    volumes: ["/opt/sonarr/recyclarr:/config"]
YML
  mv /opt/sonarr/docker-compose.yml.new /opt/sonarr/docker-compose.yml
  chown -R "$2:$3" /opt/sonarr
  cd /opt/sonarr && docker compose --profile tools config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings" "$compose" "$tz" "${ids%%:*}" "${ids##*:}"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Sonarr not started"
else
  in_ct "Downloading Sonarr and Recyclarr" 'cd /opt/sonarr && docker compose --profile tools pull -q'
  in_ct "Starting Sonarr" 'cd /opt/sonarr && docker compose up -d --remove-orphans'
  wait_page Sonarr "docker compose -f /opt/sonarr/docker-compose.yml logs --tail 50"
fi

step "Settings"
# Through Sonarr's own API (v3): Recycling Bin (a deleted or replaced file waits 7 days) and, when a SABnzbd client
# exists, "Remove Completed". Run the recipe again after adding the SABnzbd client by hand.
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no settings written"
else
  akey=$(incus exec "$ct" -- sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' /opt/sonarr/config/config.xml </dev/null 2>/dev/null | head -n1 || true)
  if [ -z "$akey" ]; then
    warn "No API key found yet, settings not written (run the recipe again)"
  else
    res=$(bash "$(dirname "$0")/arr-tune.sh" "$ip" "$PORT" "$akey" /media/downloads/recycle 7 2>/dev/null || true)
    case "$res" in *recycle=set*|*recycle=same*) ok "Recycling Bin /media/downloads/recycle, emptied after 7 days" ;; *) warn "Recycling Bin not set. Click: Settings -> Media Management -> Recycling Bin" ;; esac
    case "$res" in
      *client=set*|*client=same*) ok "The SABnzbd client removes completed downloads" ;;
      *client=none*) note "No SABnzbd client yet; add it (step 2 below), then run this recipe again for Remove Completed" ;;
      *) warn "Remove Completed not set. Click: Settings -> Download Clients -> SABnzbd -> Remove Completed" ;;
    esac
  fi
  if incus info jellyfin >/dev/null 2>&1; then
    note "Jellyfin: Settings -> Connect -> + -> Emby/Jellyfin: host, port 8096, API key (Jellyfin: Dashboard -> API Keys), tick Update Library. Not set by the recipe: the key needs a Jellyfin login"
  fi
fi

step "Backup"
# Sonarr keeps SQLite databases, which must not be copied while they are written. The dump goes to /var/backups/hs/sonarr.
install_dump_tool sqlite
media_backup "/usr/local/sbin/hs-dump sqlite-tree sonarr /opt/sonarr"
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

media_ntfy

declare_service sonarr Sonarr sonarr never-public Media "Series: searches, downloads and files them"

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings -> Media Management -> Root Folder:  /media/series")
$(say "2. Settings -> Download Clients -> SABnzbd (hs recipe sabnzbd), category  tv, then run this recipe again")
$(say "3. Prowlarr (hs recipe prowlarr): Settings -> Apps -> Sonarr, this address and the API key (Settings -> General)")
$(t 'Push messages (Settings -> Connect -> ntfy):  server %s   topic %s' "$ntfy_server" "$ntfy_topic")
$(docs_hint radarr)
DONE
