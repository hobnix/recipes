#!/usr/bin/env bash
# recipe: Prowlarr: holds your Usenet indexers and hands them to Radarr, Sonarr and Lidarr
# recipe.de: Prowlarr: verwaltet deine Usenet-Indexer und gibt sie an Radarr, Sonarr und Lidarr weiter
# kind: generic
# needs: docker
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: creates the container "prowlarr" with Docker inside and runs Prowlarr (9696, linuxserver.io image):
# your indexer(s) in one place, synced into Radarr, Sonarr and Lidarr (Settings -> Apps). The other apps of the group
# are recipes of their own (radarr, sonarr, lidarr, bazarr, maintainerr); the guide is the one of the recipe radarr.
#   config    /opt/prowlarr/config inside the container (SSD pool); `hs backup ct prowlarr on` is switched on and a
#             dump of the databases is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/prowlarr)
# No share is mounted: Prowlarr never touches a file of the library.
# No Zoraxy rule: Prowlarr is an admin page for the home network (it holds the logins of your indexers).
# Runs in one of two places (the question RUNS, `# runs: lxc docker`): the container "prowlarr" (above), or, when Docker is on
# (hs docker enable), as an app inside the container docker: compose project "prowlarr" in the share apps (recipes/prowlarr, data in its
# config folder), and the dump of the database in the backup of the container docker.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-prowlarr}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=9696   # Prowlarr's own port

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s
' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable))" "$app" "$app")"
  say "  start Prowlarr (port 9696)"
  say "  put the container in the nightly backup with a database dump"
  exit 0
fi

recipe_runtime lxc docker
if $RUNS_DOCKER; then
  child_port_free "$PORT" "$app"
else
  ensure_container "$ct" 1024 --docker
  fixed_address "$ct" 50 99
fi
wait_internet "$ct"
if $RUNS_DOCKER; then   # the one user "media" of the container docker (as in the film apps), without the share
  incus exec docker -- sh -c 'id media >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin media' </dev/null
  ids=$(incus exec docker -- sh -c 'echo "$(id -u media):$(id -g media)"' </dev/null)
fi
if ! $RUNS_DOCKER; then
  install_docker
fi

step "Prowlarr"
# docker-compose.yml is written again at every run; Prowlarr's own data stays in /opt/prowlarr/config
compose='mkdir -p /opt/prowlarr/config
  cat > /opt/prowlarr/docker-compose.yml.new <<YML
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    ports: ["9696:9696"]
    environment:
      - TZ=$1
      - PUID=1000
      - PGID=1000
      - UMASK=002
    volumes: ["/opt/prowlarr/config:/config"]
YML
  mv /opt/prowlarr/docker-compose.yml.new /opt/prowlarr/docker-compose.yml
  chown -R 1000:1000 /opt/prowlarr
  cd /opt/prowlarr && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
if $RUNS_DOCKER; then
  dir=$APP_DIR
  in_ct "Preparing the folders" 'mkdir -p "$1/config" && chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
  child_compose "$app" <<YML
services:
  $app:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: $app
    restart: unless-stopped
    ports: ["9696:9696"]
    environment:
      - TZ=$tz
      - PUID=${ids%%:*}
      - PGID=${ids##*:}
      - UMASK=002
    volumes: ["$dir/config:/config"]
YML
  in_ct "Setting the owner of the files" 'chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
else
  in_ct "Writing the settings" "$compose" "$tz"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Prowlarr not started"
else
  if $RUNS_DOCKER; then
    in_ct "Downloading Prowlarr" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$dir"
    spin "Starting Prowlarr" child_up "$app"
    wait_page Prowlarr "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50"
  else
    in_ct "Downloading Prowlarr" 'cd /opt/prowlarr && docker compose pull -q'
    in_ct "Starting Prowlarr" 'cd /opt/prowlarr && docker compose up -d --remove-orphans'
    wait_page Prowlarr "docker compose -f /opt/prowlarr/docker-compose.yml logs --tail 50"
  fi
fi

step "Backup"
# Prowlarr keeps SQLite databases, which must not be copied while they are written. The dump goes to /var/backups/hs/prowlarr.
install_dump_tool sqlite
if $RUNS_DOCKER; then
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app $APP_DIR"
else
  media_backup "/usr/local/sbin/hs-dump sqlite-tree prowlarr /opt/prowlarr"
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" Prowlarr prowlarr never-public Media "The indexers for Radarr, Sonarr and Lidarr"
else
  declare_service prowlarr Prowlarr prowlarr never-public Media "The indexers for Radarr, Sonarr and Lidarr"
fi

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Indexers -> Add Indexer: your indexer (an account you pay for yourself)")
$(say "2. Settings -> Apps: Radarr, Sonarr and Lidarr, each with its address and API key (in each app: Settings -> General)")
$(docs_hint radarr)
DONE
