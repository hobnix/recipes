#!/usr/bin/env bash
# Every recipe with a web page of its own (it asks for a port with port_setting) says what its service is: a `declare_service` call
# (docs/PLAN-modular-core.md step 4e), so a new app shows up in `hs services` and on the dashboard without anyone editing a table.
# The recipes that need no call are named here with the reason. A declared admin page must not be public-ok. No root, no server.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_RECIPES_DIR=$PKGS
R=$PKGS

# recipe -> why it declares nothing
declare -A NONE=(
  [livekit]="not a web page"
  [matrix-hook]="not a web page"
  [cloudflared]="a tunnel, no web page"
  [domain]="the domain controller, no web page"
  [catalyst-node]="a node agent, no web page"
  [sunshine]="parked"
)

echo "-- recipes with a port of their own declare their service"
missing=""
for f in "$R"/*/run.sh; do
  n=$(basename "$(dirname "$f")")
  case "$n" in _*) continue ;; esac
  grep -qE 'port_setting|setting PORT' "$f" || continue
  grep -q '^ *declare_service ' "$f" && continue
  [ -n "${NONE[$n]:-}" ] || missing+="$n "
done
check_eq "every such recipe calls declare_service (or is named in NONE)" "" "$missing"

echo "-- what they declare"
bad=$(grep -h '^ *declare_service ' "$R"/*/run.sh | awk '{
  # declare_service <name> <title> <icon> [exposure] ...: the fourth word, after the quoted title if there is one
  line = $0; sub(/^ +/, "", line); sub(/^declare_service +[^ ]+ +/, "", line)
  if (substr(line, 1, 1) == "\"") { sub(/^"[^"]*" +/, "", line) } else { sub(/^[^ ]+ +/, "", line) }
  sub(/^[^ ]+ */, "", line)
  split(line, w, " ")
  if (w[1] == "public-ok") print $0
}')
check_eq "no recipe declares its service public-ok" "" "$bad"
admin=$(for n in docker zoraxy authentik tdarr qbittorrent sabnzbd uptime-kuma monitoring paperclip stalwart; do grep -q "^ *declare_service $n .* never-public " "$R/$n/run.sh" 2>/dev/null || echo "$n "; done)
check_eq "the admin pages and download tools are never-public" "" "$admin"
count=$(grep -l '^ *declare_service ' "$R"/*/run.sh | wc -l | tr -d ' ')
check_eq "so far (update this number with a new recipe)" "22" "$count"

finish
