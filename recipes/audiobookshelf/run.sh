#!/usr/bin/env bash
# recipe: Audiobookshelf: streams your audiobooks and podcasts to phones and browsers, remembers where you stopped
# recipe.de: Audiobookshelf: streamt deine Hörbücher und Podcasts auf Handy und Browser und merkt sich, wo du aufgehört hast
# kind: generic
# needs: docker share
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: runs Audiobookshelf (ghcr.io/advplyr/audiobookshelf, the app listens on port 80 inside, 13378 outside) in one of two places
# (the question RUNS, `# runs: lxc docker`): the container "audiobookshelf" with Docker inside, or, when Docker is on (hs docker enable), as
# an app inside the container docker (compose project "audiobookshelf" in the share apps, recipes/audiobookshelf).
#   share     the share "media" (the one of Jellyfin and Lidarr), READ-WRITE at /media (a user mapped 1:1): the folders audiobooks and
#             podcasts are made there; the app gets them at /audiobooks and /podcasts READ-WRITE (it saves covers, `metadata.json` and
#             downloaded podcast episodes next to the books, and moves files when you ask it to)
#   config    <app folder>/config (SQLite database, users), <app folder>/metadata (covers, cache, the app's own backups);
#             `hs backup ct` is switched on and a dump of the database is written right before each backup (hs-dump sqlite-tree)
# Audiobookshelf has logins of its own (the first person who opens the page creates the root user), so it may be public (a Zoraxy rule is
# asked for in the step Service); finish the first login before any public name exists. The phone apps use a websocket: a proxy in front
# must pass it on.
# Not tested on hardware yet; the paths and the port are from the project's docker-compose.yml.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-audiobookshelf}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=13378   # the port outside (inside the app listens on 80)

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1024 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable); the share comes in with hs docker mount)" "$app" "$app")"
  say "  mount the share for the books (asks for its name, default media) at /media, with folders movies, series, music, downloads, audiobooks, podcasts"
  say "  start Audiobookshelf (port 13378) with /media/audiobooks and /media/podcasts as its libraries"
  say "  put the container in the nightly backup with a database dump"
  say "  (if you say yes) give it a public name through the gateway: Audiobookshelf has logins of its own"
  exit 0
fi

recipe_runtime lxc docker
setting SHARE "Name of the share with the audiobooks and podcasts (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
if $RUNS_DOCKER; then
  child_port_free "$PORT" "$app"
else
  ensure_container "$ct" 1024 --docker
  fixed_address "$ct" 20 29
fi
wait_internet "$ct"
media_storage audiobookshelf
if ! $RUNS_DOCKER; then
  install_docker
fi

step "Audiobookshelf"
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
uid=${ids%%:*}; gid=${ids##*:}
if $RUNS_DOCKER; then dir=$APP_DIR; mu=media; else dir=/opt/audiobookshelf; mu=audiobookshelf; fi
compose_file() {
  cat <<YML
services:
  $app:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: $app
    restart: unless-stopped
    user: "$uid:$gid"
    ports: ["$PORT:80"]
    environment:
      - TZ=$tz
    volumes: ["$dir/config:/config", "$dir/metadata:/metadata", "/media/audiobooks:/audiobooks", "/media/podcasts:/podcasts"]
YML
}
# the compose file is written again at every run; the app's data stays in <dir>
in_ct "Preparing the folders" 'mkdir -p "$1/config" "$1/metadata" && chown -R "$2:$3" "$1"' "$dir" "$uid" "$gid"
# the library folders belong on the share, made as the mapped user (the share is not in the container's own disk)
incus exec "$ct" -- su -s /bin/sh "$mu" -c 'mkdir -p /media/audiobooks /media/podcasts' </dev/null ||
  fail "$(t "'%s' can't make the folders audiobooks and podcasts in /media." "$mu")"
if $RUNS_DOCKER; then
  compose_file | child_compose "$app"
else
  compose_file | incus exec "$ct" -- sh -c "cat > $dir/docker-compose.yml.new && mv $dir/docker-compose.yml.new $dir/docker-compose.yml" ||
    fail "$(t "Could not write the compose file of '%s'." "$app")"
  in_ct "Checking the settings" 'cd "$1" && docker compose config -q' "$dir"
fi

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Audiobookshelf not started"
elif $RUNS_DOCKER; then
  in_ct "Downloading Audiobookshelf" 'cd "$1" && docker compose -p "$2" pull -q' "$dir" "$app"
  spin "Starting Audiobookshelf" child_up "$app"
  wait_page Audiobookshelf "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50"
else
  in_ct "Downloading Audiobookshelf" 'cd "$1" && docker compose pull -q' "$dir"
  in_ct "Starting Audiobookshelf" 'cd "$1" && docker compose up -d --remove-orphans' "$dir"
  wait_page Audiobookshelf "docker compose -f $dir/docker-compose.yml logs --tail 50"
fi

step "Backup"
# Audiobookshelf keeps a SQLite database in config (users, progress, libraries), which must not be copied while it is written.
install_dump_tool sqlite
if $RUNS_DOCKER; then
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app $dir/config"
else
  media_backup "/usr/local/sbin/hs-dump sqlite-tree audiobookshelf $dir/config"
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" Audiobookshelf audiobookshelf public-ok Media "Audiobooks and podcasts: streams them to phones and browsers"
else
  declare_service audiobookshelf Audiobookshelf audiobookshelf public-ok Media "Audiobooks and podcasts: streams them to phones and browsers"
fi

recipe_facts web
box <<DONE
$(say "Open the page and create the root login straight away (the first person to open it becomes root).")
$(say "Then Settings -> Libraries -> Add: one library for /audiobooks (type Audiobooks) and one for /podcasts (type Podcasts).")
$(say "Put each book in its own folder, Author/Title, under /media/audiobooks; the app scans it and fetches covers and descriptions.")
$(say "Phone apps: the official Audiobookshelf app (Android, iOS) with this address and your login.")
$(say "A public name is asked for in the step Service; do the first login before you say yes.")
$(docs_hint audiobookshelf)
DONE
