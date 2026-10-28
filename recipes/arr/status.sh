#!/usr/bin/env bash
# help: the services of the arr recipe: which app runs, on which port, and where to open it
# help.de: die Dienste des arr-Rezepts: welche App läuft, auf welchem Port und wo man sie öffnet
# args: [--list]
# The first command of a recipe package (docs/PLAN-packages.md): `hs ext arr status` for people, `hs sys ext arr status` as data
# (app, port, state up|down|missing, url; one line per app, no line while the container does not exist). Reads only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../scripts/lib/ui.sh"
ct=${RECIPE_NAME:-arr}
apps="radarr:7878 sonarr:8989 lidarr:8686 prowlarr:9696 bazarr:6767 maintainerr:6246"

rows() {
  local ip states a name port st
  incus info "$ct" >/dev/null 2>&1 || return 0
  ip=$(incus query "/1.0/instances/$ct?recursion=1" 2>/dev/null | jq -r '((.state.network // {}) | (.eth0 // .enp5s0 // {}) | .addresses // []) | map(select(.family == "inet")) | .[0].address // empty') || ip=""
  states=$(incus exec "$ct" -- docker ps -a --format '{{.Names}} {{.State}}' </dev/null 2>/dev/null || true)
  for a in $apps; do
    name=${a%%:*}; port=${a##*:}
    st=$(awk -v n="$name" '$1 == n { print $2 }' <<<"$states" | head -n1)
    case "$st" in running) st=up ;; "") st=missing ;; *) st=down ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$st" "${ip:+http://$ip:$port}"
  done
}

if [ "${1:-}" = --list ]; then rows; exit 0; fi
out=$(rows)
if [ -z "$out" ]; then
  note "$(t "There is no container '%s' yet." "$ct")"; next_step "hs recipe arr"; exit 0
fi
{ thead 'App' 'Port' 'State' 'Open'; printf '%s\n' "$out"; } | table
