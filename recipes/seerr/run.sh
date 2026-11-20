#!/usr/bin/env bash
# recipe: Seerr: a page where family and friends ask for films and series (works with Jellyfin and Plex)
# recipe.de: Seerr: eine Seite, auf der Familie und Freunde Filme und Serien wünschen können (läuft mit Jellyfin und Plex)
# kind: generic
# needs: docker
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: creates the container "seerr" with Docker inside and runs Seerr (the merged successor of
# Jellyseerr and Overseerr, ghcr.io/seerr-team/seerr). A request goes to Radarr or Sonarr (recipes "radarr", "sonarr"), which
# find and load it; Seerr shows what is available in Jellyfin (or Plex, later). People sign in with their
# Jellyfin account, so there is no second set of passwords.
#   config    /opt/seerr/config (SSD pool); `hs backup ct seerr on` is switched on and a dump of its database
#             is written right before each backup (/usr/local/sbin/hs-seerr-dump)
# No share is mounted: Seerr never touches a file of the library.
# Zoraxy: this is the one page of the film apps that can be shown to friends (a rule for it is YOUR decision,
# see the guide); the setup wizard is open to whoever reaches it first, so finish it before any rule exists.
# Runs in one of two places (the question RUNS, `# runs: lxc docker`): the container "seerr" (above), or, when Docker is on
# (hs docker enable), as an app inside the container docker: compose project "seerr" in the share apps (recipes/seerr, data in its
# config folder), and the dump of the database in the backup of the container docker.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-seerr}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=5055   # Seerr's own port (the lxc mode asks for it)

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s
' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable))" "$app" "$app")"
  say "  start Seerr (asks for the port, default 80)"
  say "  put the container in the nightly backup with a database dump"
  exit 0
fi

recipe_runtime lxc docker
if $RUNS_DOCKER; then
  child_port_free "$PORT" "$app"
else
  port_setting "Seerr" 5055
  ensure_container "$ct" 1024 --docker
  fixed_address "$ct" 20 29
fi
wait_internet "$ct"
if $RUNS_DOCKER; then   # the one user "media" of the container docker (as in the film apps), without the share
  incus exec docker -- sh -c 'id media >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin media' </dev/null
  ids=$(incus exec docker -- sh -c 'echo "$(id -u media):$(id -g media)"' </dev/null)
else
  install_docker
fi

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
if $RUNS_DOCKER; then
  dir=$APP_DIR
  in_ct "Preparing the folders" 'mkdir -p "$1/config" && chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
  child_compose "$app" <<YML
services:
  $app:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: $app
    init: true
    restart: unless-stopped
    user: "${ids%%:*}:${ids##*:}"
    ports: ["5055:5055"]
    environment:
      - TZ=$tz
      - LOG_LEVEL=info
    volumes: ["$dir/config:/app/config"]
YML
  in_ct "Setting the owner of the files" 'chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
else
  in_ct "Writing the settings (port)" "$compose" "$tz" "$PORT"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Seerr not started"
else
  if $RUNS_DOCKER; then
    in_ct "Downloading Seerr" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$dir"
    spin "Starting Seerr" child_up "$app"
    wait_page Seerr "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50"
  else
    in_ct "Downloading Seerr" 'cd /opt/seerr && docker compose pull -q'
    in_ct "Starting Seerr" 'cd /opt/seerr && docker compose up -d --remove-orphans'
    wait_page Seerr 'docker compose -f /opt/seerr/docker-compose.yml logs --tail 50'
  fi
fi

step "Backup"
if $RUNS_DOCKER; then
  install_dump_tool sqlite
  media_backup "/usr/local/sbin/hs-dump sqlite $app $APP_DIR/config/db/db.sqlite3"
else
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
fi

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" Seerr seerr private-ok Apps "Requests for films and series"
else
  declare_service seerr Seerr seerr private-ok Apps "Requests for films and series"
fi
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  Finish the setup wizard first (it is open to whoever gets there first): sign in with your Jellyfin")
$(say "  account, then add Radarr (http://<radarr address>:7878) and Sonarr (<sonarr address>:8989) with their API keys.")
$(say "  No Zoraxy rule yet: whether friends reach it from outside is described in the guide.")
$(docs_hint seerr)
DONE
