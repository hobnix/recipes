#!/usr/bin/env bash
# recipe: Navidrome: streams your music library to phones and browsers (Subsonic apps work with it)
# recipe.de: Navidrome: streamt deine Musikbibliothek auf Handy und Browser (Subsonic-Apps funktionieren damit)
# kind: generic
# needs: docker share
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: runs Navidrome (navidrome/navidrome, port 4533) in one of two places (the question RUNS, `# runs: lxc docker`):
# the container "navidrome" with Docker inside, or, when Docker is on (hs docker enable), as an app inside the container docker
# (compose project "navidrome" in the share apps, recipes/navidrome).
#   share     the share "media" (the one of Jellyfin and Lidarr), READ-WRITE at /media like the other music apps (a user mapped 1:1);
#             Navidrome itself gets /media/music read-only at /music
#   data      <app folder>/data (database, cover cache); `hs backup ct` is switched on and a dump of the database is written right
#             before each backup (hs-dump sqlite-tree)
# Navidrome has logins of its own (the first person who opens the page creates the admin), so it may be public (a Zoraxy rule
# is asked for in the step Service); finish the first login before any public name exists.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-navidrome}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=4533   # Navidrome's own port

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable); the share comes in with hs docker mount)" "$app" "$app")"
  say "  mount the share for the music (asks for its name, default media) at /media, with folders movies, series, music, downloads"
  say "  start Navidrome (port 4533) with /media/music read-only as its library"
  say "  put the container in the nightly backup with a database dump"
  say "  (if you say yes) give it a public name through the gateway: Navidrome has logins of its own"
  exit 0
fi

recipe_runtime lxc docker
setting SHARE "Name of the share with the music (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
if $RUNS_DOCKER; then
  child_port_free "$PORT" "$app"
else
  ensure_container "$ct" 1024 --docker
  fixed_address "$ct" 20 29
fi
wait_internet "$ct"
media_storage navidrome
if ! $RUNS_DOCKER; then
  install_docker
fi

step "Navidrome"
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
uid=${ids%%:*}; gid=${ids##*:}
if $RUNS_DOCKER; then dir=$APP_DIR; else dir=/opt/navidrome; fi
compose_file() {
  cat <<YML
services:
  $app:
    image: navidrome/navidrome:latest
    container_name: $app
    restart: unless-stopped
    user: "$uid:$gid"
    ports: ["$PORT:4533"]
    environment:
      - TZ=$tz
      - ND_LOGLEVEL=info
    volumes: ["$dir/data:/data", "/media/music:/music:ro"]
YML
}
# the compose file is written again at every run; Navidrome's data stays in <dir>/data
in_ct "Preparing the folders" 'mkdir -p "$1/data" && chown -R "$2:$3" "$1"' "$dir" "$uid" "$gid"
if $RUNS_DOCKER; then
  compose_file | child_compose "$app"
else
  compose_file | incus exec "$ct" -- sh -c "cat > $dir/docker-compose.yml.new && mv $dir/docker-compose.yml.new $dir/docker-compose.yml" ||
    fail "$(t "Could not write the compose file of '%s'." "$app")"
  in_ct "Checking the settings" 'cd "$1" && docker compose config -q' "$dir"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Navidrome not started"
elif $RUNS_DOCKER; then
  in_ct "Downloading Navidrome" 'cd "$1" && docker compose -p "$2" pull -q' "$dir" "$app"
  spin "Starting Navidrome" child_up "$app"
  wait_page Navidrome "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50"
else
  in_ct "Downloading Navidrome" 'cd "$1" && docker compose pull -q' "$dir"
  in_ct "Starting Navidrome" 'cd "$1" && docker compose up -d --remove-orphans' "$dir"
  wait_page Navidrome "docker compose -f $dir/docker-compose.yml logs --tail 50"
fi

step "Backup"
# Navidrome keeps a SQLite database (playlists, play counts, users), which must not be copied while it is written.
install_dump_tool sqlite
if $RUNS_DOCKER; then
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app $dir"
else
  media_backup "/usr/local/sbin/hs-dump sqlite-tree navidrome $dir"
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" Navidrome navidrome public-ok Media "Music: streams the library to phones and browsers"
else
  declare_service navidrome Navidrome navidrome public-ok Media "Music: streams the library to phones and browsers"
fi

recipe_facts web
box <<DONE
$(say "Open the page and create the admin login straight away (the first person to open it becomes admin).")
$(say "The library is /media/music; put albums there (hs recipe lidarr fills it) and Navidrome scans it every hour.")
$(say "Phone apps: any Subsonic app (Symfonium, DSub, Substreamer) with this address and your login.")
$(say "A public name is asked for in the step Service; do the first login before you say yes.")
$(docs_hint navidrome)
DONE
