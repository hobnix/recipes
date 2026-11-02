#!/usr/bin/env bash
# recipe: Lidarr: keeps your music in order: searches albums, sends the download to SABnzbd, files it in the library
# recipe.de: Lidarr: hält deine Musik in Ordnung: sucht Alben, schickt den Download an SABnzbd, legt ihn in der Bibliothek ab
# kind: generic
# needs: docker share
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: creates the container "lidarr" with Docker inside and runs Lidarr (8686, linuxserver.io image):
# music, searched, sent to SABnzbd, renamed and filed in /media/music. The other apps of the group are recipes of
# their own (radarr, sonarr, prowlarr, bazarr, maintainerr); the guide is the one of the recipe radarr.
#   share              the share "media" (the one of Jellyfin), READ-WRITE at /media with a user "lidarr" mapped 1:1,
#                      the same path SABnzbd uses: a finished download moves into the library by a hard link
#   config             /opt/lidarr/config inside the container (SSD pool); `hs backup ct lidarr on` is switched on and a
#                      dump of the databases is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/lidarr)
#   push messages      the topic of the film apps (state/media-ntfy), see the closing text
# Runs in one of two places (the question RUNS, `# runs: lxc docker`): the container "lidarr" (above), or, when Docker is on
# (hs docker enable), as an app inside the container docker: compose project "lidarr" in /opt/apps/lidarr (config in
# /opt/apps/lidarr/config), the share "media" at /media of the container docker with one mapped user "media" for all film apps,
# and the dump of the databases in the backup of the container docker.
# No Zoraxy rule: Lidarr is an admin page for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-lidarr}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=8686   # Lidarr's own port: Prowlarr is told this one

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  (docker mode: no container of its own: a compose project '%s' in /opt/apps/%s inside the container docker, which must be on (hs docker enable); the share comes in with hs docker mount)" "$app" "$app")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media, with folders movies, series, music, downloads"
  say "  start Lidarr (port 8686)"
  say "  use the push topic of the film apps, and put the container in the nightly backup with a database dump"
  exit 0
fi

recipe_runtime lxc docker
setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
if $RUNS_DOCKER; then
  child_port_free "$PORT" "$app"
else
  ensure_container "$ct" 1024 --docker
  fixed_address "$ct" 50 99
fi
wait_internet "$ct"
media_storage lidarr
if ! $RUNS_DOCKER; then
  install_docker
fi

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
if $RUNS_DOCKER; then
  dir=/opt/apps/$app
  in_ct "Preparing the folders" 'mkdir -p "$1/config" && chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
  # the share "media" is a local share: no rslave needed (only a folder from hs remote would need it)
  child_compose "$app" <<YML
services:
  $app:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: $app
    restart: unless-stopped
    ports: ["8686:8686"]
    environment:
      - TZ=$tz
      - PUID=${ids%%:*}
      - PGID=${ids##*:}
      - UMASK=002
    volumes: ["$dir/config:/config", "/media:/media"]
YML
  in_ct "Setting the owner of the files" 'chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
else
  in_ct "Writing the settings" "$compose" "$tz" "${ids%%:*}" "${ids##*:}"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Lidarr not started"
else
  if $RUNS_DOCKER; then
    spin "Downloading Lidarr" child_pull "$app"
    spin "Starting Lidarr" child_up "$app"
    wait_page Lidarr "docker compose -p $app -f /opt/apps/$app/docker-compose.yml logs --tail 50"
  else
    in_ct "Downloading Lidarr" 'cd /opt/lidarr && docker compose pull -q'
    in_ct "Starting Lidarr" 'cd /opt/lidarr && docker compose up -d --remove-orphans'
    wait_page Lidarr "docker compose -f /opt/lidarr/docker-compose.yml logs --tail 50"
  fi
fi

step "Backup"
# Lidarr keeps SQLite databases, which must not be copied while they are written. The dump goes to /var/backups/hs/lidarr.
install_dump_tool sqlite
if $RUNS_DOCKER; then
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app /opt/apps/$app"
else
  media_backup "/usr/local/sbin/hs-dump sqlite-tree lidarr /opt/lidarr"
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

media_ntfy

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker"; remove when core has the declare_service fix)
  RECIPE_NAME= declare_service "$app" Lidarr lidarr never-public Media "Music: searches, downloads and files it"
else
  declare_service lidarr Lidarr lidarr never-public Media "Music: searches, downloads and files it"
fi

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings -> Media Management -> Root Folder:  /media/music")
$(say "2. Settings -> Download Clients -> SABnzbd (hs recipe sabnzbd), category  audio")
$(say "3. Prowlarr (hs recipe prowlarr): Settings -> Apps -> Lidarr, this address and the API key (Settings -> General)")
$(t 'Push messages (Settings -> Connect -> ntfy):  server %s   topic %s' "$ntfy_server" "$ntfy_topic")
$(docs_hint radarr)
DONE
