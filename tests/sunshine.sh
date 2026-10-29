#!/usr/bin/env bash
# The sunshine recipe (syntax, header, dry run). `hs ext games` is tested in hobnix/extensions.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"

echo "-- recipe"
check "sunshine.sh parses" bash -n "$PKGS/sunshine/run.sh"
check "recipe has a German one-liner" grep -q '^# recipe.de: ' "$PKGS/sunshine/run.sh"
check_out "dry run names the container" "container 'sunshine'" bash "$PKGS/sunshine/run.sh" --dry-run
finish
