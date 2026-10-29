#!/usr/bin/env bash
# What `hs sys recipes` asks of a real recipe: domain needs a terminal, qbittorrent has a form (recipe-asks.sh of the core reads the header).
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
T=$(printf '\t')
export HS_LANG=en HS_PLAIN=1

check_out "domain needs a terminal" "^input${T}terminal" env HS_RECIPES_DIR=$PKGS bash "$SCRIPTS/recipe-asks.sh" domain
check_out "qbittorrent has a form" "^input${T}form" env HS_RECIPES_DIR=$PKGS bash "$SCRIPTS/recipe-asks.sh" qbittorrent
finish
