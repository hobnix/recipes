#!/usr/bin/env bash
# The film recipes (radarr, sonarr, lidarr, prowlarr, bazarr, maintainerr, sabnzbd, seerr, qbittorrent) and their shared helpers: syntax, dry runs, the guide hint,
# the push topic of their own and the backup switch. No root, no incus: a fake `incus` stands in.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_LANG=en HS_PLAIN=1
R=$PKGS            # the recipes: $R/<name>/run.sh
L=$SCRIPTS/recipes          # the shared helpers (_lib.sh, _media.sh)
STATE=$WORK/state; mkdir -p "$STATE" "$WORK/bin"

# fake incus: `info` succeeds only for FAKE_CT, `list docs` answers when FAKE_DOCS is set
cat > "$WORK/bin/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  info) [ "$2" = "${FAKE_CT:-none}" ] && exit 0; exit 1 ;;
  query) echo '{"status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","address":"10.10.95.77"}]}}},"expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:01"}}}'; exit 0 ;;
  config) [ "$2 $3" = "device get" ] && exit 1; exit 0 ;;
  list) [ "$2" = docs ] && [ -n "${FAKE_DOCS:-}" ] && echo "10.10.95.20 (eth0)"; exit 0 ;;
  exec) case "$*" in *"<ApiKey>"*) echo fakekey-123 ;; esac; exit 0 ;;   # the API key of an app (configarr)
esac
exit 0
FAKE
chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH"

echo "-- syntax and dry runs"
for r in radarr sonarr lidarr prowlarr bazarr maintainerr sabnzbd seerr jellyfin qbittorrent uchiyomi configarr; do check "$r run.sh parses" bash -n "$R/$r/run.sh"; done
for r in _media _lib; do check "$r.sh parses" bash -n "$L/$r.sh"; done
for r in radarr sonarr lidarr prowlarr bazarr maintainerr; do
  check_out "$r dry run names its container" "container '$r'" env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check_out "the dry run follows RECIPE_NAME ($r)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/$r/run.sh" --dry-run
done
for r in radarr sonarr lidarr bazarr; do
  check_out "$r mounts the share with the library folders" "folders movies, series, music, downloads" env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
done
for r in radarr sonarr lidarr prowlarr bazarr maintainerr; do
  check_out "$r dry run names the docker path too" "docker mode: no container of its own: a compose project '$r' in the share apps .recipes/$r." env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check "$r never writes a literal /opt/apps" bash -c '! grep -q "/opt/apps" "$1/run.sh"' _ "$R/$r"
  check "$r declares both runtimes (header and manifest)" bash -c 'grep -q "^# runs: lxc docker$" "$1/run.sh" && grep -q "^runs = \[\"lxc\", \"docker\"\]" "$1/package.toml" && grep -q "^requires_core = \">=6\"" "$1/package.toml"' _ "$R/$r"
done
for r in radarr sonarr; do check "$r has no Recyclarr" bash -c '! grep -qi recyclarr "$1/run.sh"' _ "$R/$r"; done
check_out "configarr dry run names its container" "container 'configarr'" env HS_STATE_DIR="$STATE" bash "$R/configarr/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (configarr)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/configarr/run.sh" --dry-run
check_out "configarr dry run names the docker path too" "docker mode: no container of its own: a compose project 'configarr'" env HS_STATE_DIR="$STATE" bash "$R/configarr/run.sh" --dry-run
check "configarr never writes a literal /opt/apps" bash -c '! grep -q "/opt/apps" "$1/run.sh"' _ "$R/configarr"
check "configarr declares both runtimes (header and manifest)" bash -c 'grep -q "^# runs: lxc docker$" "$1/run.sh" && grep -q "^runs = \[\"lxc\", \"docker\"\]" "$1/package.toml" && grep -q "^requires_core = \">=6\"" "$1/package.toml"' _ "$R/configarr"
check "configarr has a German one-liner" grep -q '^# recipe.de: ' "$R/configarr/run.sh"
check "configarr points at its own guide" grep -q "docs_hint configarr)" "$R/configarr/run.sh"
check "configarr has a guide" test -f "$R/configarr/guide.md"
check_out "radarr dry run says the duplicate job is not in docker mode" "no nightly duplicate job" env HS_STATE_DIR="$STATE" bash "$R/radarr/run.sh" --dry-run
for r in navidrome droppedneedle audiobookshelf; do
  check "$r run.sh parses" bash -n "$R/$r/run.sh"
  check "$r is executable" test -x "$R/$r/run.sh"
  check "$r has a German one-liner" grep -q '^# recipe.de: ' "$R/$r/run.sh"
  check_out "$r dry run names its container" "container '$r'" env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check_out "$r dry run names the docker path" "docker mode: no container of its own: a compose project '$r' in the share apps .recipes/$r." env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check "$r declares both runtimes (header and manifest)" bash -c 'grep -q "^# runs: lxc docker$" "$1/run.sh" && grep -q "^runs = \[\"lxc\", \"docker\"\]" "$1/package.toml"' _ "$R/$r"
  check "$r may get a public name" grep -q 'declare_service .* public-ok ' "$R/$r/run.sh"
done
check_out "sabnzbd dry run" "container 'sabnzbd'" env HS_STATE_DIR="$STATE" bash "$R/sabnzbd/run.sh" --dry-run
for r in seerr sabnzbd jellyfin; do
  check_out "$r dry run names the docker path too" "docker mode: no container of its own: a compose project '$r'" env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check "$r never writes a literal /opt/apps" bash -c '! grep -q "/opt/apps" "$1/run.sh"' _ "$R/$r"
  check "$r declares both runtimes (header and manifest)" bash -c 'grep -q "^# runs: lxc docker$" "$1/run.sh" && grep -q "^runs = \[\"lxc\", \"docker\"\]" "$1/package.toml" && grep -q "^requires_core = \">=6\"" "$1/package.toml"' _ "$R/$r"
done
check_out "jellyfin dry run names its container" "container 'jellyfin'" env HS_STATE_DIR="$STATE" bash "$R/jellyfin/run.sh" --dry-run
check_out "jellyfin dry run says a card only when docker has one" "a graphics card only when the container docker has one" env HS_STATE_DIR="$STATE" bash "$R/jellyfin/run.sh" --dry-run
check_out "seerr dry run" "container 'seerr'" env HS_STATE_DIR="$STATE" bash "$R/seerr/run.sh" --dry-run
check_out "uchiyomi dry run names the container and the manga folder" "container .uchiyomi.*|folder manga" env HS_STATE_DIR="$STATE" bash "$R/uchiyomi/run.sh" --dry-run
check_out "qbittorrent dry run names the container" "container 'qbittorrent'" env HS_STATE_DIR="$STATE" bash "$R/qbittorrent/run.sh" --dry-run
check_out "qbittorrent dry run says there is no network outside the VPN" "no network outside the VPN" env HS_STATE_DIR="$STATE" bash "$R/qbittorrent/run.sh" --dry-run
check_out "qbittorrent dry run mentions the tunnel device" "/dev/net/tun" env HS_STATE_DIR="$STATE" bash "$R/qbittorrent/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (qbittorrent)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/qbittorrent/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (sabnzbd)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/sabnzbd/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (seerr)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/seerr/run.sh" --dry-run
for r in radarr sonarr lidarr prowlarr bazarr maintainerr sabnzbd seerr jellyfin qbittorrent uchiyomi configarr; do
  check "$r is executable" test -x "$R/$r/run.sh"
  check "$r has a German one-liner" grep -q '^# recipe.de: ' "$R/$r/run.sh"
done

echo "-- qbittorrent: the construction"
check "qBittorrent has no network of its own (network_mode service:gluetun)" grep -q 'network_mode: "service:gluetun"' "$R/qbittorrent/run.sh"
check "qBittorrent waits for a healthy tunnel" grep -q 'condition: service_healthy' "$R/qbittorrent/run.sh"
check "the VPN login is written inside the container, root only" grep -q 'umask 077; cat > \$vpn_env' "$R/qbittorrent/run.sh"
check "downloads land under /media/downloads/torrents" grep -q '/media/downloads/torrents' "$R/qbittorrent/run.sh"
check "the web page gets no Zoraxy rule" test -z "$(grep -v '^ *#' "$R/qbittorrent/run.sh" | grep -i 'proxy rule' || true)"

echo "-- every guide a recipe names exists, and every recipe names one"
slug() { printf '%s' "$1" | sed -e 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/Ä/Ae/g; s/Ö/Oe/g; s/Ü/Ue/g; s/ß/ss/g' | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'; }
slugs=" "
for f in "$ROOT"/docs/*.md; do slugs="$slugs$(slug "$(basename "$f" .md)") "; done
for f in "$PKGS"/*/guide.md "$ROOT"/capabilities/*/guide.md; do [ -f "$f" ] && slugs="$slugs$(basename "$(dirname "$f")") "; done
for f in "$R"/*/run.sh; do
  n=$(sed -n 's/.*docs_hint \([a-z0-9-]*\).*/\1/p' "$f" | head -n1)
  if [ -z "$n" ]; then fail "$(basename "$(dirname "$f")"): the closing text has no guide hint"; continue; fi
  case "$slugs" in *" $n "*) pass "$(basename "$(dirname "$f")"): guide $n exists" ;; *) fail "$(basename "$(dirname "$f")"): no guide with the slug $n" ;; esac
done
for r in radarr sonarr lidarr prowlarr bazarr maintainerr sabnzbd seerr; do
  check "$r has a guide of its own" test -f "$R/$r/guide.md"
  check "$r points at its own guide" grep -q "docs_hint $r)" "$R/$r/run.sh"
done

echo "-- full runs with the skip knobs (a fake incus, a throwaway container name)"
if have jq; then
  for r in sabnzbd radarr sonarr lidarr prowlarr bazarr maintainerr seerr qbittorrent uchiyomi; do
    out=$(env FAKE_CT=throwaway-ct RECIPE_NAME=throwaway-ct RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
    check_eq "$r runs through with the skip knobs" 0 "$rc"
    if grep -q "throwaway-ct" <<<"$out" && grep -q "nightly backup" <<<"$out"; then pass "$r names the container and the backup"; else fail "$r names the container and the backup ($(tail -n 3 <<<"$out" | tr '\n' ' '))"; fi
  done
else
  skip "full runs with the skip knobs need jq"
fi

echo "-- docker mode (a child of the container docker): fake incus that records, fake hs docker status"
if have jq; then
  mkdir -p "$WORK/dbin"
  cat > "$WORK/dbin/incus" <<'FAKE'
#!/usr/bin/env bash
# records every call; `info` fails (no instance of the app's name), `exec docker -- sh -c "... id -u ..."` answers the mapped user,
# the compose file arrives on stdin of `exec docker -- sh -c "... cat > <app folder>/docker-compose.yml.new ..."` and is kept
echo "$*" >> "$DLOG"
case "$1" in
  info) exit 1 ;;
  query) echo '{"status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","address":"10.1.2.3"}]}}},"expanded_devices":{}}'; exit 0 ;;
  exec) case "$*" in
      *"for d in"*) exit 1 ;;   # no folder of the app yet: a new app goes to the share apps
      *"docker-compose.yml.new"*)  cat > "$DCOMPOSE" ;;
      *"<ApiKey>"*) echo fakekey-123 ;;   # the API key of Radarr/Sonarr (the sed on config.xml)
      *"id -u"*) echo "1500:1500" ;;
    esac; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$WORK/dbin/incus"
  cat > "$WORK/dstatus" <<'FAKE'
#!/bin/sh
printf 'state	on
running	yes
address	10.1.2.3
'
FAKE
  chmod +x "$WORK/dstatus"
  for r in radarr sonarr lidarr bazarr; do
    DST=$WORK/dstate-$r; rm -rf "$DST"; mkdir -p "$DST"; export DLOG=$WORK/dlog-$r DCOMPOSE=$WORK/dcompose-$r; : > "$DLOG"
    out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
    check_eq "$r in docker mode runs through" 0 "$rc"
    check "$r docker: answers stay in recipe-$r.conf" test -f "$DST/recipe-$r.conf"
    check "$r docker: no container of its own is created" bash -c '! grep -qE "^(launch|init|create) |manage-ct" "$1"' _ "$DLOG"
    check "$r docker: nothing is installed in the parent for Docker" bash -c '! grep -q "get.docker.com\|docker-ce\|install -y.*docker" "$1"' _ "$DLOG"
    check "$r docker: the compose file goes to the share apps" grep -q "/shares/apps/recipes/$r/docker-compose.yml.new" "$DLOG"
    check "$r docker: the compose file is checked with the project name" grep -q "docker compose -p $r config -q" "$DLOG"
    check "$r docker: container_name is the app" grep -q "container_name: $r\$" "$DCOMPOSE"
    check "$r docker: runs as the mapped user" grep -q "PUID=1500" "$DCOMPOSE"
    check "$r docker: config under the share apps" grep -q "/shares/apps/recipes/$r/config:/config" "$DCOMPOSE"
    check "$r docker: the share is /media:/media" grep -q '"/media:/media"' "$DCOMPOSE"
    check "$r docker: no nested volume of the old path" bash -c '! grep -q "/opt/$2/" "$1"' _ "$DCOMPOSE" "$r"
    check "$r docker: the dump goes to the descriptor of docker" grep -q "sqlite-tree $r /shares/apps/recipes/$r" "$DST/backup-dump/docker"
    check_out "$r docker: the summary names the parent" "docker" echo "$out"
    case $r in radarr|sonarr) check "$r docker: no Recyclarr any more" bash -c '! grep -qi recyclarr "$1"' _ "$DCOMPOSE" ;; esac
  done
  for r in navidrome droppedneedle audiobookshelf prowlarr maintainerr; do
    DST=$WORK/dstate-$r; rm -rf "$DST"; mkdir -p "$DST"; export DLOG=$WORK/dlog-$r DCOMPOSE=$WORK/dcompose-$r; : > "$DLOG"
    out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
    check_eq "$r in docker mode runs through" 0 "$rc"
    check "$r docker: no container of its own is created" bash -c '! grep -qE "^(launch|init|create) |manage-ct" "$1"' _ "$DLOG"
    check "$r docker: the compose file goes to the share apps" grep -q "/shares/apps/recipes/$r/docker-compose.yml.new" "$DLOG"
    check "$r docker: answers stay in recipe-$r.conf" test -f "$DST/recipe-$r.conf"
    check "$r docker: no literal /opt/apps in the compose file" bash -c '! grep -q "/opt/apps" "$1"' _ "$DCOMPOSE"
    check "$r docker: container_name is the app" grep -q "container_name: $r\$" "$DCOMPOSE"
    check "$r docker: data under the share apps" grep -q "/shares/apps/recipes/$r/" "$DCOMPOSE"
    check "$r docker: the dump goes to the descriptor of docker" grep -q "sqlite-tree $r /shares/apps/recipes/$r" "$DST/backup-dump/docker"
  done
  check "radarr docker: the dedupe job is not installed" bash -c '! grep -q "hs-arr-dedupe" "$1"' _ "$WORK/dlog-radarr"
  out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 RECIPE_NAME=radarr2 HS_STATE_DIR="$WORK/dstate-r2" bash "$R/radarr/run.sh" 2>&1 </dev/null); rc=$?
  check_eq "a second radarr (--name) runs in docker mode" 0 "$rc"
  check "the second radarr has its own answers file" test -f "$WORK/dstate-r2/recipe-radarr2.conf"
  # sabnzbd: the share at /media, unfinished downloads off the share, no dump (the settings are in the share apps)
  for r in sabnzbd; do
    DST=$WORK/dstate-$r; rm -rf "$DST"; mkdir -p "$DST"; export DLOG=$WORK/dlog-$r DCOMPOSE=$WORK/dcompose-$r; : > "$DLOG"
    out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
    check_eq "$r in docker mode runs through" 0 "$rc"
    check "$r docker: no container of its own is created" bash -c '! grep -qE "^(launch|init|create) |manage-ct" "$1"' _ "$DLOG"
    check "$r docker: the compose file goes to the share apps" grep -q "/shares/apps/recipes/$r/docker-compose.yml.new" "$DLOG"
    check "$r docker: container_name is the app" grep -q "container_name: $r\$" "$DCOMPOSE"
    check "$r docker: runs as the mapped user" grep -q "PUID=1500" "$DCOMPOSE"
    check "$r docker: the share is /media:/media" grep -q '"/media:/media"' "$DCOMPOSE"
    check "$r docker: config under the share apps" grep -q "/shares/apps/recipes/$r/config:/config" "$DCOMPOSE"
    check "$r docker: no literal /opt/apps in the compose file" bash -c '! grep -q "/opt/apps" "$1"' _ "$DCOMPOSE"
    check "$r docker: answers stay in recipe-$r.conf" test -f "$DST/recipe-$r.conf"
    check "$r docker: in the backup list, no dump" test ! -s "$DST/backup-dump/docker"
  done
  # seerr: its database goes to the descriptor of docker
  for r in seerr; do
    DST=$WORK/dstate-$r; rm -rf "$DST"; mkdir -p "$DST"; export DLOG=$WORK/dlog-$r DCOMPOSE=$WORK/dcompose-$r; : > "$DLOG"
    out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
    check_eq "$r in docker mode runs through" 0 "$rc"
    check "$r docker: no container of its own is created" bash -c '! grep -qE "^(launch|init|create) |manage-ct" "$1"' _ "$DLOG"
    check "$r docker: the compose file goes to the share apps" grep -q "/shares/apps/recipes/$r/docker-compose.yml.new" "$DLOG"
    check "$r docker: container_name is the app" grep -q "container_name: $r\$" "$DCOMPOSE"
    check "$r docker: runs as the mapped user" grep -q 'user: "1500:1500"' "$DCOMPOSE"
    check "$r docker: init is on" grep -q "init: true" "$DCOMPOSE"
    check "$r docker: config under the share apps" grep -q "/shares/apps/recipes/$r/config:/app/config" "$DCOMPOSE"
    check "$r docker: no literal /opt/apps in the compose file" bash -c '! grep -q "/opt/apps" "$1"' _ "$DCOMPOSE"
    check "$r docker: answers stay in recipe-$r.conf" test -f "$DST/recipe-$r.conf"
    check "$r docker: the dump goes to the descriptor of docker" grep -q "sqlite seerr /shares/apps/recipes/seerr/config/db/db.sqlite3" "$DST/backup-dump/docker"
  done
  # jellyfin: the library read-only, no device is ever added to docker, no card in the fake: the CPU warning
  for r in jellyfin; do
    DST=$WORK/dstate-$r; rm -rf "$DST"; mkdir -p "$DST"; export DLOG=$WORK/dlog-$r DCOMPOSE=$WORK/dcompose-$r; : > "$DLOG"
    out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
    check_eq "$r in docker mode runs through" 0 "$rc"
    check "$r docker: no container of its own is created" bash -c '! grep -qE "^(launch|init|create) |manage-ct" "$1"' _ "$DLOG"
    check "$r docker: the compose file goes to the share apps" grep -q "/shares/apps/recipes/$r/docker-compose.yml.new" "$DLOG"
    check "$r docker: container_name is the app" grep -q "container_name: $r\$" "$DCOMPOSE"
    check "$r docker: the library is read-only" grep -q '"/media:/media:ro"' "$DCOMPOSE"
    check "$r docker: no graphics device without a card in docker" bash -c '! grep -q "/dev/dri" "$1"' _ "$DCOMPOSE"
    check "$r docker: no device is added to the container docker" bash -c '! grep -q "config device add" "$1"' _ "$DLOG"
    check "$r docker: no literal /opt/apps in the compose file" bash -c '! grep -q "/opt/apps" "$1"' _ "$DCOMPOSE"
    check_out "$r docker: says it converts on the CPU" "converts videos on the CPU" echo "$out"
    check "$r docker: answers stay in recipe-$r.conf" test -f "$DST/recipe-$r.conf"
    check "$r docker: the dump goes to the descriptor of docker" grep -q "sqlite-tree $r /shares/apps/recipes/$r/config" "$DST/backup-dump/docker"
  done
  # configarr: a git repository over SSH, secrets.yml through stdin only, pinned images
  r=configarr
  DST=$WORK/dstate-$r; rm -rf "$DST"; mkdir -p "$DST"; export DLOG=$WORK/dlog-$r DCOMPOSE=$WORK/dcompose-$r; : > "$DLOG"
  out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker RECIPE_PROFILE_REPO=git@github.com:example/profiles.git HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
  check_eq "$r in docker mode runs through" 0 "$rc"
  check "$r docker: no container of its own is created" bash -c '! grep -qE "^(launch|init|create) |manage-ct" "$1"' _ "$DLOG"
  check "$r docker: the compose file goes to the share apps" grep -q "/shares/apps/recipes/$r/docker-compose.yml.new" "$DLOG"
  check "$r docker: container_name is the app" grep -q "container_name: $r\$" "$DCOMPOSE"
  check "$r docker: the git service has its own name" grep -q "container_name: $r-git\$" "$DCOMPOSE"
  check "$r docker: Configarr reads the config of the repository" grep -q "CONFIG_LOCATION=/profile/config.yml" "$DCOMPOSE"
  check "$r docker: the repository is mounted read-only" grep -q '"/shares/apps/recipes/configarr/profile:/profile:ro"' "$DCOMPOSE"
  check "$r docker: templates and custom formats are mounted" grep -q '/profile/templates:/app/templates:ro", "/shares/apps/recipes/configarr/profile/cfs:/app/cfs:ro"' "$DCOMPOSE"
  check "$r docker: secrets.yml comes from its own folder" grep -q '"/shares/apps/recipes/configarr/secrets:/secrets:ro"' "$DCOMPOSE"
  check "$r docker: both images are pinned (no :latest)" bash -c '! grep -q ":latest" "$1" && grep -q "image: ghcr.io/raydak-labs/configarr:[0-9]" "$1" && grep -q "image: alpine/git:[0-9]" "$1"' _ "$DCOMPOSE"
  check "$r docker: no port is published" bash -c '! grep -q "ports:" "$1"' _ "$DCOMPOSE"
  check "$r docker: nothing is skipped when both apps are found" grep -q "SKIP_KINDS=\$" "$DCOMPOSE"
  check "$r docker: no API key in any command line" bash -c '! grep -q "fakekey-123" "$1"' _ "$DLOG"
  check "$r docker: secrets.yml is written with umask 077" grep -q "umask 077; cat > .\$1/secrets/secrets.yml.new" "$DLOG"
  check "$r docker: GitHub's host key is written" grep -q "/shares/apps/recipes/configarr/hs/ssh/known_hosts" "$DLOG"
  check "$r docker: the backup list names docker, no dump" test ! -s "$DST/backup-dump/docker"
  check "$r docker: answers stay in recipe-$r.conf" test -f "$DST/recipe-$r.conf"
  check "$r docker: the repository address is remembered" grep -q "^PROFILE_REPO=git@github.com:example/profiles.git$" "$DST/recipe-$r.conf"
  check_out "$r docker: the run does not print the key" "." echo "$out"
  check "$r docker: the output has no API key" bash -c '! grep -q "fakekey-123" <<<"$1"' _ "$out"
  # no repository: stops and says how to ask
  DST=$WORK/dstate-$r-norepo; rm -rf "$DST"; mkdir -p "$DST"; : > "$DLOG"
  out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
  check "$r without a repository stops" test "$rc" -ne 0
  check_out "$r without a repository names the fix" "hs recipe configarr --ask" echo "$out"
  # a repository address that is not SSH is refused
  out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker RECIPE_PROFILE_REPO=https://github.com/example/profiles.git HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
  check "$r refuses an address that is not SSH" test "$rc" -ne 0
  # the same under another name
  DST=$WORK/dstate-$r-2; rm -rf "$DST"; mkdir -p "$DST"; : > "$DLOG"
  out=$(env PATH="$WORK/dbin:$PATH" RECIPE_RUNS=docker RECIPE_PROFILE_REPO=git@github.com:example/profiles.git HS_DOCKER_STATUS="$WORK/dstatus" RECIPE_SKIP_PULL=1 RECIPE_NAME=configarr2 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
  check_eq "a second configarr (--name) runs in docker mode" 0 "$rc"
  check "the second configarr has its own answers file" test -f "$DST/recipe-configarr2.conf"
  # its own container (lxc mode)
  DST=$WORK/dstate-$r-lxc; rm -rf "$DST"; mkdir -p "$DST"
  out=$(env FAKE_CT=throwaway-ct RECIPE_NAME=throwaway-ct RECIPE_PROFILE_REPO=git@github.com:example/profiles.git RECIPE_SKIP_PULL=1 HS_STATE_DIR="$DST" bash "$R/$r/run.sh" 2>&1 </dev/null); rc=$?
  check_eq "$r runs through in its own container" 0 "$rc"
  check "$r lxc: the container is in the nightly backup" grep -q "nightly backup" <<<"$out"
  unset DLOG DCOMPOSE
else
  skip "docker mode checks need jq"
fi

echo "-- configarr: the four scripts written by the recipe are valid POSIX sh"
mkdir -p "$WORK/cscripts"
check "the scripts can be written for the test" env CONFIGARR_WRITE_SCRIPTS="$WORK/cscripts" bash "$R/configarr/run.sh"
for f in pull loop-git run loop-run; do check "configarr $f.sh parses (sh -n)" sh -n "$WORK/cscripts/$f.sh"; done
check "configarr run.sh leaves out the block of a missing app" bash -c 'printf "radarr:
  main:
    base_url: x
sonarr:
  main:
    api_key: y
" > "$1/in.yml" && awk -v skip="sonarr" '"'"'BEGIN { n = split(skip, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 } /^[A-Za-z_]/ { k = $0; sub(/:.*/, "", k); drop = (k in s) } !drop { print }'"'"' "$1/in.yml" | grep -q radarr && ! awk -v skip="sonarr" '"'"'BEGIN { n = split(skip, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 } /^[A-Za-z_]/ { k = $0; sub(/:.*/, "", k); drop = (k in s) } !drop { print }'"'"' "$1/in.yml" | grep -q sonarr' _ "$WORK"

echo "-- arr-tune.sh (Recycling Bin, Remove Completed) against a fake curl"
check "arr-tune.sh parses" bash -n "$R/radarr/arr-tune.sh"
check "radarr and sonarr have the same arr-tune.sh" cmp -s "$R/radarr/arr-tune.sh" "$R/sonarr/arr-tune.sh"
if have jq; then
  cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# fake Radarr/Sonarr: state in $FAKE_DIR; prints the answer, records every PUT
url=""; method=GET; data=""
while [ $# -gt 0 ]; do case "$1" in -X) method=$2; shift ;; -d) data=$2; shift ;; http*) url=$1 ;; esac; shift; done
case "$method $url" in
  "GET "*/config/mediamanagement) cat "$FAKE_DIR/mm.json" ;;
  "PUT "*/config/mediamanagement) echo "$data" > "$FAKE_DIR/mm.json"; echo put-mm >> "$FAKE_DIR/log" ;;
  "GET "*/downloadclient) cat "$FAKE_DIR/dc.json" ;;
  "PUT "*/downloadclient/*) echo "[$data]" > "$FAKE_DIR/dc.json"; echo put-dc >> "$FAKE_DIR/log" ;;
  *) exit 22 ;;
esac
FAKE
  chmod +x "$WORK/bin/curl"
  export FAKE_DIR=$WORK/fakeapp; mkdir -p "$FAKE_DIR"
  echo '{"id":1,"recycleBin":"","recycleBinCleanupDays":7,"copyUsingHardlinks":true}' > "$FAKE_DIR/mm.json"
  echo '[]' > "$FAKE_DIR/dc.json"; : > "$FAKE_DIR/log"
  out=$(bash "$R/radarr/arr-tune.sh" 10.0.0.1 7878 k /media/downloads/recycle 7)
  check_out "recycle bin is set" "recycle=set" echo "$out"
  check_out "no SABnzbd client: reported, nothing invented" "client=none" echo "$out"
  check_eq "the other fields are kept" true "$(jq -r .copyUsingHardlinks "$FAKE_DIR/mm.json")"
  echo '[{"id":3,"implementation":"Sabnzbd","removeCompletedDownloads":false,"name":"S"}]' > "$FAKE_DIR/dc.json"
  out=$(bash "$R/radarr/arr-tune.sh" 10.0.0.1 7878 k /media/downloads/recycle 7)
  check_out "second run: bin unchanged" "recycle=same" echo "$out"
  check_out "Remove Completed is switched on" "client=set" echo "$out"
  check_eq "removeCompletedDownloads true" true "$(jq -r '.[0].removeCompletedDownloads' "$FAKE_DIR/dc.json")"
  out=$(bash "$R/radarr/arr-tune.sh" 10.0.0.1 7878 k /media/downloads/recycle 7)
  check_out "third run changes nothing" "recycle=same.*|client=same" echo "$out"
  check_eq "exactly one PUT per setting over three runs" 2 "$(wc -l < "$FAKE_DIR/log" | tr -d ' ')"
  rm -f "$WORK/bin/curl"
else
  skip "arr-tune.sh checks need jq"
fi

echo "-- helpers"
driver=$WORK/driver.sh
cat > "$driver" <<DRV
set -euo pipefail
scripts=$SCRIPTS
state=$STATE
ct=\${CT:-probe}
. $L/_lib.sh
. $L/_media.sh
"\$@"
DRV
helper() { bash "$driver" "$@"; }

printf 'hostName = "hs"
webPort = 8481
' > "$WORK/machine-docs.toml"
check_out "guide hint without the Docs page says where the file is" "docs/ of the repository" env HS_CAPABILITIES_FILE=/nonexistent HS_CAPABILITIES_TSV=/nonexistent bash "$driver" docs_hint some-guide
printf 'docs
' > "$WORK/caps-docs"
check_out "guide hint with the Docs page links the page" "http://hs.local:8481/docs/en/some-guide" env HS_CAPABILITIES_FILE="$WORK/caps-docs" HS_MACHINE_FILE="$WORK/machine-docs.toml" bash "$driver" docs_hint some-guide

rm -f "$STATE/media-ntfy"   # an earlier dry run may have made one
echo "https://ntfy.example.org/alarm-topic-123" > "$STATE/notify-url"
helper media_ntfy
line=$(cat "$STATE/media-ntfy" 2>/dev/null || true)
check_out "push topic: same server as the alarms" "^https://ntfy.example.org hs-media-[0-9a-f]{20}$" echo "$line"
case "$line" in *alarm-topic-123*) fail "the film topic is not the alarm topic" ;; *) pass "the film topic is not the alarm topic" ;; esac
helper media_ntfy
check_eq "push topic is made once and kept" "$line" "$(cat "$STATE/media-ntfy")"
rm -f "$STATE/media-ntfy" "$STATE/notify-url"
helper media_ntfy
check_out "push topic without any alarm address uses ntfy.sh" "^https://ntfy.sh hs-media-" cat "$STATE/media-ntfy"

echo "-- backup switch"
HS_STATE_DIR=$STATE CT=probe FAKE_CT=probe helper media_backup "/usr/local/sbin/dump-it" >/dev/null 2>&1 || true
check_eq "the dump command is written" "/usr/local/sbin/dump-it" "$(grep -v '^#' "$STATE/backup-dump/probe" 2>/dev/null || true)"
check_out "the container is listed for the backup" "^probe$" cat "$STATE/backup-instances"
HS_STATE_DIR=$STATE CT=quiet FAKE_CT=quiet helper media_backup "" >/dev/null 2>&1 || true
check "no dump file when the command is empty" test ! -e "$STATE/backup-dump/quiet"

finish
