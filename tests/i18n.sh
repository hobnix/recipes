#!/usr/bin/env bash
# The German texts of the recipes: every recipe has a German one-liner, every text it prints is translated (in its own i18n/de.tsv or in the
# core catalog), nothing in its catalog is unused, the placeholders agree, and a run in German really prints German. No root.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
CATALOG=$CORE/scripts/lib/i18n/de.tsv
KEYS="python3 -I $CORE/scripts/dev/i18n-keys.py"
has() { [ -f "$1" ] && awk -F'	' -v k="$2" '$1 == k { f = 1 } END { exit !f }' "$1"; }   # the exact text, not a part of a longer one

echo "-- one-liners"
nodoc=""; for f in "$PKGS"/*/run.sh; do grep -q '^# recipe\.de: ' "$f" || nodoc="$nodoc $(basename "$(dirname "$f")")"; done
check_eq "every recipe has a German description (# recipe.de:)" "" "$nodoc"

echo "-- the texts of each recipe"
missing=""; stale=""; ph=""
for f in "$PKGS"/*/run.sh; do
  r=$(basename "$(dirname "$f")"); own=$PKGS/$r/i18n/de.tsv
  keys=$($KEYS "$f")
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qF -- "$(printf '%s\t' "$k")" "$CATALOG" 2>/dev/null || grep -qF -- "$(printf '%s\t' "$k")" "$own" 2>/dev/null || missing="$missing [$r: $k]"
  done <<<"$keys"
  [ -f "$own" ] || continue
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && [ "${k:0:1}" != "#" ] || continue
    grep -qxF -- "$k" <<<"$keys" || stale="$stale [$r: $k]"
    [ "$(grep -o '%[sd]' <<<"$k" | wc -l)" = "$(grep -o '%[sd]' <<<"$v" | wc -l)" ] || ph="$ph [$r: $k]"
  done < "$own"
done
check_eq "every text of every recipe is translated" "" "$(head -c 600 <<<"$missing")"
check_eq "no translation of a recipe is unused" "" "$(head -c 600 <<<"$stale")"
check_eq "every translation keeps its placeholders" "" "$(head -c 600 <<<"$ph")"

echo "-- a run in German"
export HS_STATE_DIR=$WORK/state HS_PLAIN=1; mkdir -p "$HS_STATE_DIR"
en=$(HS_LANG=en bash "$PKGS/steamos/run.sh" --dry-run 2>&1 | head -40)
de=$(HS_LANG=de bash "$PKGS/steamos/run.sh" --dry-run 2>&1 | head -40)
if [ "$en" != "$de" ] && [ -n "$en" ]; then pass "a dry run in German differs from English"; else fail "a dry run in German differs from English"; fi
finish
