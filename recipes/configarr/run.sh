#!/usr/bin/env bash
# recipe: Configarr: syncs the quality profiles and custom formats of Radarr and Sonarr from your own git repository, every night
# recipe.de: Configarr: überträgt Qualitätsprofile und Custom Formats aus deinem eigenen Git-Repository jede Nacht nach Radarr und Sonarr
# kind: generic
# needs: docker
# uses: -
# runs: lxc docker
set -euo pipefail

# What it does: runs Configarr (ghcr.io/raydak-labs/configarr, pinned tag) as a compose project with two services that have no web page:
#   <app>-git          alpine/git: pulls your PRIVATE profile repository with a read-only deploy key that this recipe makes (every night at
#                      SYNC_TIME, and when you ask: see the guide)
#   <app>              Configarr: runs when a pull has brought a config.yml, and writes the profiles into Radarr and Sonarr
# The repository holds config.yml (it uses !secret RADARR_URL, RADARR_API_KEY, SONARR_URL, SONARR_API_KEY), optionally templates/ and cfs/.
# The addresses and API keys come from secrets.yml, which this recipe writes ON THE SERVER (never into the repository), from the config.xml
# of the Radarr and Sonarr it finds: the instance or the Docker app of that name. Only one of them is fine: the block of the other is left out.
# Runs in one of two places (`# runs: lxc docker`): the container "configarr" with Docker inside (/opt/configarr), or as an app inside the
# container docker (compose project in the share apps, recipes/configarr). Both services run as root inside their own Docker container.
# Files (D = /opt/configarr, or the folder of the app in docker mode): D/hs (the scripts this recipe writes, ssh key, state/*.status, logs/),
# D/profile (the clone), D/secrets/secrets.yml (mode 600), D/repos (the cache of the TRaSH guides).
# A failed sync is seen in D/hs/state/run.status and pull.status, in the logs, and as a push message to the topic of the film apps
# (only after one pull has worked: a key that is not added yet makes no noise). Its guide is guide.md beside this file.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1 RECIPE_PROFILE_REPO=<ssh address>
#             CONFIGARR_WRITE_SCRIPTS=<folder> (writes the four scripts there and stops: for `sh -n`)
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-configarr}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
CONFIGARR_IMAGE=ghcr.io/raydak-labs/configarr:1.39.2
GIT_IMAGE=alpine/git:2.54.1
# the ed25519 key of github.com (docs.github.com, "GitHub's SSH key fingerprints")
GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

# ── the four scripts that run inside the containers (POSIX sh, busybox-safe), written at every run ──
script_pull() { cat <<'SH'
#!/bin/sh
# Pull the profile repository into /profile with the deploy key (written by the recipe configarr: edits are lost at its next run).
S=/hs/state; L=/hs/logs/pull.log; why=""
mkdir -p "$S" /hs/logs /profile
pull() {
  cd /profile || { why="no /profile folder"; return 1; }
  [ -d .git ] || git init -q || { why="git init failed"; return 1; }
  git remote set-url origin "$PROFILE_REPO" 2>/dev/null || git remote add origin "$PROFILE_REPO" || { why="git remote failed"; return 1; }
  git fetch -q --depth 1 origin HEAD || { why="git fetch failed (is the deploy key added? see pull.log)"; return 1; }
  git reset -q --hard FETCH_HEAD || { why="git reset failed"; return 1; }
  [ -f /profile/config.yml ] || { why="config.yml missing at the repo root"; return 1; }
}
{ echo "== $(date '+%F %T') pull $PROFILE_REPO"; pull; } >>"$L" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  echo "ok $(date +%Y-%m-%dT%H:%M:%S) pulled" > "$S/pull.status"
  : > "$S/pulled-once"
  : > "$S/run-now"
else
  echo "failed $(date +%Y-%m-%dT%H:%M:%S) $why" > "$S/pull.status"
fi
tail -n 500 "$L" > "$L.t" && mv "$L.t" "$L"
exit $rc
SH
}
script_loop_git() { cat <<'SH'
#!/bin/sh
# Every 30 seconds: a pull that was asked for (state/pull-now), and the nightly pull at SYNC_TIME (HH:MM).
S=/hs/state
mkdir -p "$S" /hs/logs
# the image has no time zone data: without it `date` shows UTC and SYNC_TIME would be off
[ -e "/usr/share/zoneinfo/${TZ:-UTC}" ] || apk add -q --no-cache tzdata >/dev/null 2>&1 || true
while :; do
  if [ -e "$S/pull-now" ]; then rm -f "$S/pull-now"; sh /hs/pull.sh || true; fi
  if [ "$(date +%H:%M)" = "$SYNC_TIME" ] && [ "$(cat "$S/last-day" 2>/dev/null)" != "$(date +%F)" ]; then
    date +%F > "$S/last-day"
    sh /hs/pull.sh || true
  fi
  sleep 30
done
SH
}
script_run() { cat <<'SH'
#!/bin/sh
# One Configarr run: output into logs/run-<day>.log, result into state/run.status. DRY_RUN=true: output to the screen, nothing changes.
S=/hs/state
mkdir -p "$S" /hs/logs
cd /app || exit 1
cfg=/profile/config.yml
if [ -n "${SKIP_KINDS:-}" ]; then   # an app that is not installed: its block (a top-level key) is left out of a copy
  cfg=/tmp/config.yml
  awk -v skip="$SKIP_KINDS" 'BEGIN { n = split(skip, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 }
    /^[A-Za-z_]/ { k = $0; sub(/:.*/, "", k); drop = (k in s) }
    !drop { print }' /profile/config.yml > "$cfg"
fi
go() { echo "== $(date '+%F %T') configarr"; CONFIG_LOCATION=$cfg dumb-init node index.js; }
if [ "${DRY_RUN:-}" = true ]; then go; exit $?; fi
go >>"/hs/logs/run-$(date +%F).log" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  echo "ok $(date +%Y-%m-%dT%H:%M:%S) synced" > "$S/run.status"
else
  echo "failed $(date +%Y-%m-%dT%H:%M:%S) configarr exit $rc" > "$S/run.status"
fi
ls -1r /hs/logs/run-*.log 2>/dev/null | tail -n +15 | while read -r f; do rm -f "$f"; done
exit $rc
SH
}
script_loop_run() { cat <<'SH'
#!/bin/sh
# Every 30 seconds: a run that is waiting (state/run-now, made by a good pull), and a push message for a failed pull or run
# (only after one pull has worked, and once per failure: the status line holds the time).
S=/hs/state
mkdir -p "$S" /hs/logs
notify() {   # notify <message>
  [ -s /secrets/ntfy ] || return 0
  node -e 'const u = require("fs").readFileSync("/secrets/ntfy", "utf8").trim(); fetch(u, { method: "POST", headers: { Title: "Configarr", Priority: "high" }, body: process.argv[1] }).catch(() => {})' "$1" || true
}
while :; do
  if [ -e "$S/run-now" ]; then rm -f "$S/run-now"; sh /hs/run.sh || true; fi
  if [ -e "$S/pulled-once" ]; then
    for k in pull run; do
      st=$(cat "$S/$k.status" 2>/dev/null || true)
      case "$st" in
        failed*)
          if [ "$st" != "$(cat "$S/$k.notified" 2>/dev/null || true)" ]; then
            echo "$st" > "$S/$k.notified"
            notify "Configarr: $k $st"
          fi ;;
      esac
    done
  fi
  sleep 30
done
SH
}

if [ -n "${CONFIGARR_WRITE_SCRIPTS:-}" ]; then
  mkdir -p "$CONFIGARR_WRITE_SCRIPTS"
  script_pull > "$CONFIGARR_WRITE_SCRIPTS/pull.sh"; script_loop_git > "$CONFIGARR_WRITE_SCRIPTS/loop-git.sh"
  script_run > "$CONFIGARR_WRITE_SCRIPTS/run.sh"; script_loop_run > "$CONFIGARR_WRITE_SCRIPTS/loop-run.sh"
  exit 0
fi

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 512 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable))" "$app" "$app")"
  say "  make a read-only deploy key and show its public half (add it to your repository)"
  say "  find Radarr and Sonarr and write their addresses and API keys into secrets.yml on the server (never into the repository)"
  say "  pull the repository and run Configarr every night at the time you choose (default 03:45)"
  exit 0
fi

recipe_runtime lxc docker
setting PROFILE_REPO "SSH address of your profile repository (git@github.com:<owner>/<repo>.git)" "" "" "(([A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+)(\.git)?)?"
setting SYNC_TIME "Time of the nightly sync (HH:MM)" 03:45 03:45 "([01][0-9]|2[0-3]):[0-5][0-9]"
setting RADARR_NAME "Name of the Radarr instance or app" radarr radarr "$a_name"
setting SONARR_NAME "Name of the Sonarr instance or app" sonarr sonarr "$a_name"
[ -n "$PROFILE_REPO" ] || fail_fix "$(t 'No profile repository set.')" "hs recipe configarr --ask"
repo_host=${PROFILE_REPO#*@}; repo_host=${repo_host%%:*}

if $RUNS_DOCKER; then
  D=$APP_DIR; sn=$app
else
  D=/opt/configarr; sn=configarr
  ensure_container "$ct" 512 --docker
  fixed_address "$ct" 50 99
fi
wait_internet "$ct"
if ! $RUNS_DOCKER; then
  install_docker
fi

# the address and the API key of one app: "url<TAB>key", or nothing. Tries the instance of that name, then the Docker app of that name
arr_find() {   # arr_find <kind> <name> <port>
  local kind=$1 name=$2 port=$3 where aip akey old=/opt   # (the folder of an app of an older docker mode: $old/apps/<name>)
  for where in "$name:/opt/$kind/config/config.xml" "docker:$old/apps/$name/config/config.xml" "docker:/shares/apps/recipes/$name/config/config.xml"; do
    aip=$(address "${where%%:*}" 2>/dev/null) && [ -n "$aip" ] || continue
    akey=$(incus exec "${where%%:*}" -- sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "${where#*:}" </dev/null 2>/dev/null | head -n1 || true)
    [ -n "$akey" ] || continue
    printf '%s\t%s\n' "http://$aip:$port" "$akey"
    return 0
  done
  return 0
}
# put <path> <mode>: stdin becomes the file in the container (not through spin: it would drop stdin)
put() { incus exec "$ct" -- sh -c 'cat > "$1.new" && chmod "$2" "$1.new" && mv "$1.new" "$1"' sh "$1" "$2" || fail "$(t "Could not write %s." "$1")"; }

step "Radarr and Sonarr"
skip_kinds=""; secrets_txt=""
for kind in radarr sonarr; do
  case $kind in radarr) name=$RADARR_NAME; port=7878; KIND=RADARR; label=Radarr ;; *) name=$SONARR_NAME; port=8989; KIND=SONARR; label=Sonarr ;; esac
  found=$(arr_find "$kind" "$name" "$port")
  if [ -z "$found" ]; then
    note "$(t "No %s found (instance or Docker app '%s'): it is left out of the sync. Install it with: hs recipe %s" "$label" "$name" "$kind")"
    skip_kinds="$skip_kinds $kind"
    continue
  fi
  url=${found%%$'\t'*}
  # the key stays in this variable: never in argv, never printed
  secrets_txt="$secrets_txt${KIND}_URL: $url"$'\n'"${KIND}_API_KEY: ${found#*$'\t'}"$'\n'
  ok "$(t '%s: %s' "$label" "$url")"
done
skip_kinds=${skip_kinds# }
[ "$skip_kinds" != "radarr sonarr" ] || fail_fix "$(t "No Radarr and no Sonarr found (instance or Docker app '%s', '%s')." "$RADARR_NAME" "$SONARR_NAME")" "hs recipe radarr"

step "Files"
in_ct "Preparing the folders" 'mkdir -p "$1/hs/ssh" "$1/hs/state" "$1/hs/logs" "$1/profile/templates" "$1/profile/cfs" "$1/secrets" "$1/repos" && chmod 700 "$1/hs/ssh" "$1/secrets"' "$D"
script_pull | put "$D/hs/pull.sh" 755
script_loop_git | put "$D/hs/loop-git.sh" 755
script_run | put "$D/hs/run.sh" 755
script_loop_run | put "$D/hs/loop-run.sh" 755
ok "The scripts are in $D/hs"
# written again at every run, so a changed key follows; the text goes through stdin only
printf '%s' "$secrets_txt" | incus exec "$ct" -- sh -c 'umask 077; cat > "$1/secrets/secrets.yml.new" && mv "$1/secrets/secrets.yml.new" "$1/secrets/secrets.yml"' sh "$D" ||
  fail "$(t 'Could not write secrets.yml.')"
ok "secrets.yml (mode 600, on this server only)"
if [ "$repo_host" = github.com ]; then
  printf '%s\n' "$GITHUB_HOST_KEY" | put "$D/hs/ssh/known_hosts" 644
fi

step "Configarr"
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
media_ntfy
# the push address (it holds the topic) goes through stdin into a file, never into argv or the environment
printf '%s
' "$ntfy_server/$ntfy_topic" | incus exec "$ct" -- sh -c 'umask 077; cat > "$1/secrets/ntfy.new" && mv "$1/secrets/ntfy.new" "$1/secrets/ntfy"' sh "$D" ||
  fail "$(t 'Could not write the push address.')"
compose_yml() { cat <<YML
services:
  $sn-git:
    image: $GIT_IMAGE
    container_name: $sn-git
    restart: unless-stopped
    entrypoint: ["/bin/sh", "/hs/loop-git.sh"]
    environment:
      - TZ=$tz
      - SYNC_TIME=$SYNC_TIME
      - PROFILE_REPO=$PROFILE_REPO
      - GIT_SSH_COMMAND=ssh -i /hs/ssh/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/hs/ssh/known_hosts -o StrictHostKeyChecking=yes
    volumes: ["$D/hs:/hs", "$D/profile:/profile"]
  $sn:
    image: $CONFIGARR_IMAGE
    container_name: $sn
    restart: unless-stopped
    entrypoint: ["/bin/sh", "/hs/loop-run.sh"]
    environment:
      - TZ=$tz
      - LOG_LEVEL=info
      - CONFIG_LOCATION=/profile/config.yml
      - SECRETS_LOCATION=/secrets/secrets.yml
      - CUSTOM_REPO_ROOT=/app/repos
      - SKIP_KINDS=$skip_kinds
    volumes: ["$D/hs:/hs", "$D/profile:/profile:ro", "$D/profile/templates:/app/templates:ro", "$D/profile/cfs:/app/cfs:ro", "$D/secrets:/secrets:ro", "$D/repos:/app/repos"]
YML
}
if $RUNS_DOCKER; then
  compose_yml | child_compose "$app"
else
  compose_yml | put "$D/docker-compose.yml" 644
  in_ct "Checking the compose file" 'cd "$1" && docker compose config -q' "$D"
fi
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Configarr not started"
else
  if $RUNS_DOCKER; then
    in_ct "Downloading Configarr" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$D"
    spin "Starting Configarr" child_up "$app"
  else
    in_ct "Downloading Configarr" 'cd "$1" && docker compose pull -q' "$D"
    in_ct "Starting Configarr" 'cd "$1" && docker compose up -d --remove-orphans' "$D"
  fi
fi

step "Deploy key"
pub=""
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no deploy key made"
else
  incus exec "$ct" -- test -s "$D/hs/ssh/id_ed25519" </dev/null ||
    in_ct "Making the deploy key" 'docker run --rm --entrypoint ssh-keygen -v "$2/hs/ssh:/ssh" "$1" -q -t ed25519 -N "" -C hobnix-configarr -f /ssh/id_ed25519 && chmod 600 "$2/hs/ssh/id_ed25519"' "$GIT_IMAGE" "$D"
  if ! incus exec "$ct" -- sh -c 'grep -q "^$2[ ,]" "$1/hs/ssh/known_hosts" 2>/dev/null' sh "$D" "$repo_host" </dev/null; then
    in_ct "Taking the host key of $repo_host" 'docker run --rm --entrypoint ssh-keyscan "$1" -t ed25519 "$3" > "$2/hs/ssh/known_hosts.add" && test -s "$2/hs/ssh/known_hosts.add" && cat "$2/hs/ssh/known_hosts.add" >> "$2/hs/ssh/known_hosts" && rm -f "$2/hs/ssh/known_hosts.add"' "$GIT_IMAGE" "$D" "$repo_host"
    warn "$(t 'The host key of %s was taken on first contact; check its fingerprint.' "$repo_host")"
  fi
  pub=$(incus exec "$ct" -- cat "$D/hs/ssh/id_ed25519.pub" </dev/null 2>/dev/null || true)   # the public half: fine to show
  [ -n "$pub" ] || warn "No public key found in $D/hs/ssh"

  step "First pull"
  if incus exec "$ct" -- docker exec "$sn-git" sh /hs/pull.sh </dev/null >/dev/null 2>&1; then
    ok "$(t 'The repository is pulled; Configarr runs within a minute (log: %s/hs/logs)' "$D")"
  else
    warn "$(t 'Could not pull the repository yet: add the key below as a deploy key (read only), then run this recipe again.')"
  fi
fi

step "Backup"
# the container (lxc) or the share apps (docker) holds the key, the scripts, secrets.yml and the clone: no database to dump
media_backup ""
if ! $RUNS_DOCKER; then
  ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"
fi

recipe_facts
if [ -n "$pub" ]; then publine=$(t 'Deploy key (add it read-only to the repository: Settings -> Deploy keys): %s' "$pub"); else publine=""; fi
box <<DONE
$publine
$(t 'Nightly sync at %s. Sync now: see the guide.' "$SYNC_TIME")
$(docs_hint configarr)
DONE
