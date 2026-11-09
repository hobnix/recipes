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
esac
exit 0
FAKE
chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH"

echo "-- syntax and dry runs"
for r in radarr sonarr lidarr prowlarr bazarr maintainerr sabnzbd seerr qbittorrent uchiyomi; do check "$r run.sh parses" bash -n "$R/$r/run.sh"; done
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
check_out "radarr dry run says the duplicate job is not in docker mode" "no nightly duplicate job" env HS_STATE_DIR="$STATE" bash "$R/radarr/run.sh" --dry-run
for r in navidrome droppedneedle; do
  check "$r run.sh parses" bash -n "$R/$r/run.sh"
  check "$r is executable" test -x "$R/$r/run.sh"
  check "$r has a German one-liner" grep -q '^# recipe.de: ' "$R/$r/run.sh"
  check_out "$r dry run names its container" "container '$r'" env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check_out "$r dry run names the docker path" "docker mode: no container of its own: a compose project '$r' in the share apps .recipes/$r." env HS_STATE_DIR="$STATE" bash "$R/$r/run.sh" --dry-run
  check "$r declares both runtimes (header and manifest)" bash -c 'grep -q "^# runs: lxc docker$" "$1/run.sh" && grep -q "^runs = \[\"lxc\", \"docker\"\]" "$1/package.toml"' _ "$R/$r"
  check "$r may get a public name" grep -q 'declare_service .* public-ok ' "$R/$r/run.sh"
done
check_out "sabnzbd dry run" "container 'sabnzbd'" env HS_STATE_DIR="$STATE" bash "$R/sabnzbd/run.sh" --dry-run
check_out "seerr dry run" "container 'seerr'" env HS_STATE_DIR="$STATE" bash "$R/seerr/run.sh" --dry-run
check_out "uchiyomi dry run names the container and the manga folder" "container .uchiyomi.*|folder manga" env HS_STATE_DIR="$STATE" bash "$R/uchiyomi/run.sh" --dry-run
check_out "qbittorrent dry run names the container" "container 'qbittorrent'" env HS_STATE_DIR="$STATE" bash "$R/qbittorrent/run.sh" --dry-run
check_out "qbittorrent dry run says there is no network outside the VPN" "no network outside the VPN" env HS_STATE_DIR="$STATE" bash "$R/qbittorrent/run.sh" --dry-run
check_out "qbittorrent dry run mentions the tunnel device" "/dev/net/tun" env HS_STATE_DIR="$STATE" bash "$R/qbittorrent/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (qbittorrent)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/qbittorrent/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (sabnzbd)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/sabnzbd/run.sh" --dry-run
check_out "the dry run follows RECIPE_NAME (seerr)" "container 'throwaway-ct'" env HS_STATE_DIR="$STATE" RECIPE_NAME=throwaway-ct bash "$R/seerr/run.sh" --dry-run
for r in radarr sonarr lidarr prowlarr bazarr maintainerr sabnzbd seerr qbittorrent uchiyomi; do
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
    case $r in radarr|sonarr) check "$r docker: Recyclarr gets a name of its own" grep -q "container_name: $r-recyclarr" "$DCOMPOSE" ;; esac
  done
  for r in navidrome droppedneedle prowlarr maintainerr; do
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
  unset DLOG DCOMPOSE
else
  skip "docker mode checks need jq"
fi

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
