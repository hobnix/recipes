#!/usr/bin/env bash
# The steamos recipe (syntax, dry run, header). No root, no incus.
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
R=$PKGS/steamos/run.sh

check "steamos.sh parses" bash -n "$R"
check "recipe has a German one-liner" grep -q '^# recipe.de: ' "$R"
check_out "dry run names the container" "container 'steamos'" bash "$R" --dry-run
check "no Docker in the recipe" bash -c '! grep -qE "^ *(install_docker|nvidia_docker)" "$1"' _ "$R"
check "no raw.lxc device rule (it stops the container from booting)" bash -c '! grep -q "^ *incus config set .*raw.lxc" "$1"' _ "$R"
check "VNC is flagged as an admin port" grep -q "steamos.*5900" "$SCRIPTS/ports.sh"
finish
