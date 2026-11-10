#!/usr/bin/env bash
# The claude-vm recipe (syntax, dry run, header, no secret on a command line). No root, no incus.
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
R=$PKGS/claude-vm/run.sh

check "claude-vm run.sh parses" bash -n "$R"
check "recipe has a German one-liner" grep -q '^# recipe.de: ' "$R"
check_out "dry run names the virtual machine" "virtual machine 'claude-vm'" bash "$R" --dry-run
check_out "dry run names the share" "fast share" bash "$R" --dry-run
check_out "dry run names Remote Desktop" "xrdp" bash "$R" --dry-run
check_out "dry run names Claude Code" "Claude Code" bash "$R" --dry-run
check_out "dry run names the sizes" "8192 MB RAM, 4 CPUs" bash "$R" --dry-run
check "the VM is created with --vm" grep -q 'ensure_container "\$ct" 8192 --vm' "$R"
check "xrdp and xorgxrdp are installed" grep -q 'xrdp xorgxrdp' "$R"
check "dev starts xfce4-session from ~/.xsession" grep -q 'xfce4-session.*\.xsession' "$R"
check "the Remote Control unit is a template with the spec text" bash -c 'grep -q "claude-remote@.service" "$1" && grep -q "WorkingDirectory=/srv/repos/%i" "$1" && grep -q "remote-control --spawn worktree" "$1" && grep -q "RestartSec=30" "$1"' _ "$R"
check "no instance of the unit is enabled" bash -c '! grep -q "enable.*claude-remote@" "$1"' _ "$R"
check "RustDesk is gone (only the clean-up of version 1 names it)" bash -c '! grep -v "^ *#" "$1" | grep -i rustdesk | grep -vE "dpkg -s rustdesk|disable --now rustdesk|purge -y -qq rustdesk|hs-rustdesk.desktop"' _ "$R"
check "lightdm auto login is not written" bash -c '! grep -q "autologin-user=" "$1"' _ "$R"
check "the SSH key is asked and passed as an argument" grep -q 'setting SSHKEY' "$R"
check "the key fingerprint of Anthropic is checked" grep -q 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE "$R"
check "the password goes in as a file, not as an argument of incus exec" bash -c '! grep -nE "(in_ct|incus exec).*\\$pw" "$1"' _ "$R"
check "no Zoraxy rule" bash -c '! grep -q "declare_service" "$1"' _ "$R"
finish
