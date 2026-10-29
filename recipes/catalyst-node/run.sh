#!/usr/bin/env bash
# recipe: Catalyst node: runs the game servers of the Catalyst panel (containerd and the Rust agent)
# recipe.de: Catalyst-Node: führt die Spieleserver des Catalyst-Panels aus (containerd und der Rust-Agent)
# kind: generic
# needs: -
# input: form
# ask: DEPLOY_CMD|Install command of the node (Admin -> Nodes -> Register Node; it starts with curl)|secret|||
# uses: -
set -euo pipefail

# What it does: creates the container "catalyst-node" (nesting on, so containerd can run
# inside) and runs the install command the panel gives you for a new node. That
# command installs containerd, the CNI plugins and the agent, which connects to the
# panel from the inside (no port has to be opened for it).
# Before: hs recipe catalyst-panel, then in the panel Admin -> Nodes -> Register Node
# and copy the install command of the last step.
#   paste it when the recipe asks, or give it up front (it holds a token, so no history):
#   sudo RECIPE_DEPLOY_CMD='curl ... | sudo bash -x' hs recipe catalyst-node
# Without a loop mount (an unprivileged container) Catalyst keeps plain folders and does not
# enforce disk quotas. A virtual machine has no such limit: RECIPE_VM=1 (first run only, 100 GB disk).
# Experimental software: a test setup.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-catalyst-node}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (nesting on, 8192 MB RAM limit) unless it exists, with a fixed address (.30 to .39) if UniFi is connected (hs net setup)" "$ct")"
  say "  ask for the install command of the node (panel: Admin -> Nodes -> Register Node) and run it inside"
  say "  wait until the agent runs"
  exit 0
fi

kind=(--docker)
# a VM gets a 20 GB disk by default: too small for a game server and its quota (Enshrouded wants at least 20 GB)
[ "${RECIPE_VM:-}" != 1 ] || kind=(--vm --disk 100)
ensure_container "$ct" 8192 "${kind[@]}"
fixed_address "$ct" 30 39
wait_internet "$ct"

step "Agent"
if incus exec "$ct" -- systemctl is-active --quiet catalyst-agent </dev/null 2>/dev/null; then
  ok "The agent runs already"
else
  cmd=$(answer DEPLOY_CMD)
  if [ -z "$cmd" ]; then
    interactive || fail "There is no install command. Register the node in the panel (Admin -> Nodes -> Register Node), then run:  sudo RECIPE_DEPLOY_CMD='<the command>' hs recipe catalyst-node"
    cmd=$(ask_secret "Install command of the node (Admin -> Nodes -> Register Node):")
  fi
  # the container's root needs no sudo, and the trace of -x would print the token
  case "$cmd" in curl*) ;; *) fail "That does not look like the install command of the panel (it starts with curl)." ;; esac
  cmd=${cmd//"bash -x"/bash}
  in_ct "Installing curl and sudo" '$1 update -qq && $1 install -y -qq curl sudo ca-certificates' "$apt_quick"
  # the command holds a single-use token: it goes in as a file that is removed again, not on a command line
  printf '%s\n' "$cmd" | incus exec "$ct" -- sh -c 'umask 077; cat > /root/.catalyst-deploy.sh'
  spin "Installing containerd and the agent" incus exec "$ct" -- bash -c 'bash /root/.catalyst-deploy.sh; rc=$?; rm -f /root/.catalyst-deploy.sh; exit $rc' ||
    fail "$(t "The installer failed. Look at: incus exec %s -- journalctl -u catalyst-agent -n 50" "$ct")"
fi
spin "Waiting for the agent" bash -c 'for _ in $(seq 1 60); do incus exec "$1" -- systemctl is-active --quiet catalyst-agent </dev/null 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$ct" ||
  fail "$(t "The agent does not run. Look at: incus exec %s -- journalctl -u catalyst-agent -n 50" "$ct")"
ok "The agent runs"

recipe_facts
box <<DONE
$(say "The node shows as online in the panel (Admin -> Nodes) within a minute.")
$(say "Then: Admin -> Templates (a game), then create a server on this node.")
$(say "Games are not tunneled: friends reach them over Tailscale, as with Pelican.")
$(docs_hint containers-and-apps)
DONE
