#!/usr/bin/env bash
# recipe: Maintainerr: cleans up unwatched films and series by rules you write (it has none at first, deletes nothing)
# recipe.de: Maintainerr: räumt nicht angesehene Filme und Serien nach deinen eigenen Regeln auf (hat zuerst keine, löscht nichts)
# kind: generic
# needs: docker
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: creates the container "maintainerr" with Docker inside and runs Maintainerr (6246, its makers' image):
# rules YOU write (watched by nobody for a year, ...) collect films and series and, only when you switch it on, delete
# them through Radarr and Sonarr. It starts with no rules. The other apps of the group are recipes of their own
# (radarr, sonarr, lidarr, prowlarr, bazarr); the guide is the one of the recipe radarr.
#   config    /opt/maintainerr/data inside the container (SSD pool); `hs backup ct maintainerr on` is switched on and a
#             dump of the database is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/maintainerr)
# No share is mounted: Maintainerr deletes through Radarr and Sonarr, never by itself.
# No Zoraxy rule: Maintainerr is an admin page for the home network.
# Runs in one of two places (the question RUNS, `# runs: lxc docker`): the container "maintainerr" (above), or, when Docker is on
# (hs docker enable), as an app inside the container docker: compose project "maintainerr" in the share apps (recipes/maintainerr, data in its
# data folder), and the dump of the database in the backup of the container docker.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-maintainerr}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=6246   # Maintainerr's own port

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s
' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable))" "$app" "$app")"
  say "  start Maintainerr (port 6246), with no rules: it deletes nothing until you write one"
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
if $RUNS_DOCKER; then
  dir=$APP_DIR
  in_ct "Preparing the folders" 'mkdir -p "$1/data" && chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
  child_compose "$app" <<YML
services:
  $app:
    image: ghcr.io/maintainerr/maintainerr:latest
    container_name: $app
    user: "${ids%%:*}:${ids##*:}"
    restart: unless-stopped
    ports: ["6246:6246"]
    environment:
      - TZ=$tz
    volumes: ["$dir/data:/opt/data"]
YML
  in_ct "Setting the owner of the files" 'chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
else
  in_ct "Writing the settings" "$compose" "$tz"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Maintainerr not started"
else
  if $RUNS_DOCKER; then
    in_ct "Downloading Maintainerr" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$dir"
    spin "Starting Maintainerr" child_up "$app"
    wait_page Maintainerr "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50"
  else
    in_ct "Downloading Maintainerr" 'cd /opt/maintainerr && docker compose pull -q'
    in_ct "Starting Maintainerr" 'cd /opt/maintainerr && docker compose up -d --remove-orphans'
    wait_page Maintainerr "docker compose -f /opt/maintainerr/docker-compose.yml logs --tail 50"
  fi
fi

step "Backup"
# Maintainerr keeps a SQLite database, which must not be copied while it is written. The dump goes to /var/backups/hs/maintainerr.
install_dump_tool sqlite
if $RUNS_DOCKER; then
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app $APP_DIR"
else
  media_backup "/usr/local/sbin/hs-dump sqlite-tree maintainerr /opt/maintainerr"
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" Maintainerr maintainerr never-public Media "Cleans up unwatched media by your own rules"
else
  declare_service maintainerr Maintainerr maintainerr never-public Media "Cleans up unwatched media by your own rules"
fi

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings: connect Jellyfin (or Plex), Radarr and Sonarr (addresses and API keys), Seerr if you have it")
$(say "2. Rules: make a rule as a collection first, look at what it would hit, only then switch deleting on")
$(docs_hint radarr)
DONE
