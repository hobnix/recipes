#!/usr/bin/env bash
# The guide of a recipe (guide.md): one H1, short, no raw HTML, no "$ " prompt in a command block (docs/GUIDE-TEMPLATE.md of the core). No root.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
bad=""
for f in "$HERE"/recipes/*/guide.md; do
  [ -f "$f" ] || continue
  n=$(basename "$(dirname "$f")")
  [ "$(grep -c '^# ' "$f")" = 1 ] || bad="$bad [one H1:$n]"
  [ "$(wc -l < "$f")" -le 220 ] || bad="$bad [too long:$n]"
  grep -qE '<(p|br|div|span|details|summary|img|a|table|b|i|small|center)[ >/]' "$f" && bad="$bad [html:$n]"
  grep -qE '^```bash$' "$f" && awk '/^```bash$/ { inb = 1; next } /^```/ { inb = 0 } inb && /^\$ / { print FILENAME; exit }' "$f" | grep -q . && bad="$bad [prompt:$n]"
done
check_eq "a guide has one H1, stays short, has no raw HTML and no prompt in a command block" "" "$bad"
finish
