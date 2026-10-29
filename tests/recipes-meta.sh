#!/usr/bin/env bash
# The header lines of every recipe (scripts/recipe.sh recipe_needs): kind, needs and uses are there, use known words, and say what the
# script does (docker <-> install_docker, tailscale <-> "tailscale up", gpu <-> nvidia_gpu/nvidia_docker). No server needed.
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
for f in "$R"/*/run.sh; do
  n=$(basename "$(dirname "$f")")
  kind=$(sed -n 's/^# kind: //p' "$f"); needs=$(sed -n 's/^# needs: //p' "$f"); uses=$(sed -n 's/^# uses: //p' "$f")
  check "$n: kind is generic or personal" bash -c '[ "$1" = generic ] || [ "$1" = personal ]' _ "$kind"
  check "$n: needs lists known words (docker share tailscale) or -" bash -c 'for w in $1; do case $w in docker|share|tailscale|-) ;; *) exit 1 ;; esac; done; [ -n "$1" ]' _ "$needs"
  check "$n: uses lists known words (gpu) or -" bash -c 'for w in $1; do case $w in gpu|-) ;; *) exit 1 ;; esac; done; [ -n "$1" ]' _ "$uses"
  input=$(sed -n 's/^# input: //p' "$f"); asks=$(grep -c '^# ask: ' "$f" || true)
  check "$n: input is none, form or terminal" bash -c 'case $1 in none|form|terminal) ;; *) exit 1 ;; esac' _ "${input:-none}"
  if [ "${input:-none}" = form ]; then check "$n: a form recipe declares questions" test "$asks" -gt 0; else check "$n: only a form recipe declares questions" test "$asks" -eq 0; fi
  # every question: KEY|label|kind|default|pattern|when, a known kind, and the recipe reads the answer (answer KEY or RECIPE_KEY)
  while IFS='|' read -r qk ql qt qd qp qw _; do
    [ -n "$qk" ] || continue
    check "$n: question $qk has a label and a known kind" bash -c '[ -n "$1" ] && case $2 in text|secret|choice:*) ;; *) exit 1 ;; esac' _ "$ql" "$qt"
    check "$n: the recipe reads the answer to $qk" grep -qE "answer $qk|RECIPE_$qk|setting $qk" "$f"
  done < <(sed -n 's/^# ask: //p' "$f")
  has() { grep -qE "$1" "$f"; }
  if has '^ *(install_docker|nvidia_docker)\b'; then d=yes; else d=no; fi
  case " $needs " in *" docker "*) w=yes ;; *) w=no ;; esac
  [ "$n" = docker ] && continue   # it installs Docker: nobody needs it first
  check_eq "$n: 'needs docker' matches the script (install_docker)" "$d" "$w"
  if has 'tailscale up|^ *ct_tailscale$'; then d=yes; else d=no; fi
  case " $needs " in *" tailscale "*) w=yes ;; *) w=no ;; esac
  check_eq "$n: 'needs tailscale' matches the script (tailscale up)" "$d" "$w"
  if has '(^|[^_a-z])nvidia_gpu "'; then d=yes; else d=no; fi
  case " $uses " in *" gpu "*) w=yes ;; *) w=no ;; esac
  check_eq "$n: 'uses gpu' matches the script (nvidia_gpu)" "$d" "$w"
done
echo "-- hs recipe --list"
if have column; then
  out=$(COLUMNS=250 HS_PLAIN=1 HS_LANG=en bash "$SCRIPTS/recipe.sh" --list 2>&1)
  check_out "has a NEEDS column" "NEEDS" echo "$out"
  check_out "livekit needs docker and tailscale and is personal" "docker tailscale [(]personal[)]" echo "$out"
  check_out "jellyfin needs a share" "share" echo "$out"
else
  skip "hs recipe --list needs column (util-linux/bsdextrautils)"
fi
finish
