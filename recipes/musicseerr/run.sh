#!/usr/bin/env bash
# recipe: MusicSeerr: a page where family and friends discover music and ask for albums (since v2 its name is DroppedNeedle)
# recipe.de: MusicSeerr: eine Seite, auf der Familie und Freunde Musik entdecken und Alben wünschen können (seit v2 heißt es DroppedNeedle)
# kind: generic
# needs: docker share
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: runs MusicSeerr (image habirabbu/droppedneedle, port 8688) in one of two places (the question RUNS,
# `# runs: lxc docker`): the container "musicseerr" with Docker inside, or, when Docker is on (hs docker enable), as an app inside the
# container docker (compose project "musicseerr" in /opt/apps/musicseerr). Since v2.0.0 (July 2026) the project is called
# DroppedNeedle and no longer needs Lidarr; the old image name habirabbu/musicseerr gets the same builds.
#   share     the share "media" READ-WRITE at /media (a user mapped 1:1) and in the app at /data, so the library is /data/music and a
#             finished download of SABnzbd (/data/downloads/usenet/complete) is on the same filesystem
#   config    <app folder>/config, cache, plugins; `hs backup ct` is switched on and a dump of the database is written before each backup
# The app has logins of its own (the first person who opens the page creates the admin), so it may be public (asked for in the step
# Service); finish the first login before any public name exists.
# Not tested on hardware yet; the paths and variables are from the project's README.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-musicseerr}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=8688   # the app's own port

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1536 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  (docker mode: no container of its own: a compose project '%s' in /opt/apps/%s inside the container docker, which must be on (hs docker enable); the share comes in with hs docker mount)" "$app" "$app")"
  say "  mount the share for the music (asks for its name, default media) at /media, with folders movies, series, music, downloads"
  say "  start MusicSeerr (port 8688) with the share at /data"
  say "  put the container in the nightly backup with a database dump"
  say "  (if you say yes) give it a public name through the gateway: MusicSeerr has logins of its own"
  exit 0
fi

recipe_runtime lxc docker
setting SHARE "Name of the share with the music (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
if $RUNS_DOCKER; then
  child_port_free "$PORT" "$app"
else
  ensure_container "$ct" 1536 --docker
  fixed_address "$ct" 20 29
fi
wait_internet "$ct"
media_storage musicseerr
if ! $RUNS_DOCKER; then
  install_docker
fi

step "MusicSeerr"
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
uid=${ids%%:*}; gid=${ids##*:}
if $RUNS_DOCKER; then dir=$APP_DIR; else dir=/opt/musicseerr; fi
compose_file() {
  cat <<YML
services:
  $app:
    image: habirabbu/droppedneedle:latest
    container_name: $app
    restart: unless-stopped
    ports: ["$PORT:8688"]
    environment:
      - PUID=$uid
      - PGID=$gid
      - UMASK=002
      - PORT=8688
      - TZ=$tz
      - SLSKD_DOWNLOADS_PATH=/data/slskd/complete
    volumes: ["$dir/config:/app/config", "$dir/cache:/app/cache", "$dir/plugins:/app/plugins", "/media:/data"]
YML
}
# the compose file is written again at every run; the app's data stays in <dir>
in_ct "Preparing the folders" 'mkdir -p "$1/config" "$1/cache" "$1/plugins" && chown -R "$2:$3" "$1"' "$dir" "$uid" "$gid"
if $RUNS_DOCKER; then
  compose_file | child_compose "$app"
else
  compose_file | incus exec "$ct" -- sh -c "cat > $dir/docker-compose.yml.new && mv $dir/docker-compose.yml.new $dir/docker-compose.yml" ||
    fail "$(t "Could not write the compose file of '%s'." "$app")"
  in_ct "Checking the settings" 'cd "$1" && docker compose config -q' "$dir"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, MusicSeerr not started"
elif $RUNS_DOCKER; then
  in_ct "Downloading MusicSeerr" 'cd "$1" && docker compose -p "$2" pull -q' "$dir" "$app"
  spin "Starting MusicSeerr" child_up "$app"
  wait_page MusicSeerr "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50"
else
  in_ct "Downloading MusicSeerr" 'cd "$1" && docker compose pull -q' "$dir"
  in_ct "Starting MusicSeerr" 'cd "$1" && docker compose up -d --remove-orphans' "$dir"
  wait_page MusicSeerr "docker compose -f $dir/docker-compose.yml logs --tail 50"
fi

step "Backup"
# The app keeps SQLite databases in config, which must not be copied while they are written (the cache and plugins are fetched again).
install_dump_tool sqlite
if $RUNS_DOCKER; then
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app $dir/config"
else
  media_backup "/usr/local/sbin/hs-dump sqlite-tree musicseerr $dir/config"
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" MusicSeerr musicseerr public-ok Media "Music: discover and request albums"
else
  declare_service musicseerr MusicSeerr musicseerr public-ok Media "Music: discover and request albums"
fi

recipe_facts web
box <<DONE
$(say "Open the page and create the admin login straight away (it is open to whoever gets there first).")
$(say "Then Settings -> Download Client: SABnzbd (hs recipe sabnzbd) and/or slskd; the library is /data/music.")
$(say "A public name is asked for in the step Service; do the first login before you say yes.")
$(docs_hint musicseerr)
DONE
