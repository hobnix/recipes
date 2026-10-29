#!/usr/bin/env bash
# recipe: ntfy, your own server for push messages; this server's warnings are sent through it
# recipe.de: ntfy, dein eigener Server für Handy-Nachrichten; die Warnungen dieses Servers laufen darüber
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "ntfy", installs ntfy from its own
# package source, gives it a fixed address (if UniFi is connected), and points
# `hs notify` / `hs health` at a private topic on it.
# The phone reaches it only inside the home network (or through Tailscale):
# there is deliberately no Zoraxy rule, the server has no login.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-ntfy}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (512 MB RAM limit) unless it exists" "$ct")"
  say "  reserve the first free address from .40 upwards in UniFi, if UniFi is connected (hs net setup)"
  say "  install ntfy inside and write /etc/ntfy/server.yml"
  printf '%s\n' "$(t '  write %s/notify-url so hs notify sends there, and send a test message' "$state")"
  exit 0
fi

port_setting "ntfy" 80
ensure_container "$ct" 512
# the notification address contains the IP, so it must not change
fixed_address "$ct"
wait_internet "$ct"

step "Install ntfy"
if incus exec "$ct" -- sh -c 'command -v ntfy' >/dev/null 2>&1 </dev/null; then
  ok "installed already"
else
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing curl" '$1 install -y -qq curl ca-certificates gnupg' "$apt_quick"
  in_ct "Adding the ntfy package source" '
    mkdir -p /etc/apt/keyrings
    curl -fsSL -m 60 https://archive.ntfy.sh/apt/keyring.gpg -o /etc/apt/keyrings/ntfy.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main" > /etc/apt/sources.list.d/ntfy.list
    $1 update -qq' "$apt_quick"
  in_ct "Installing ntfy" '$1 install -y -qq ntfy' "$apt_quick"
fi
note "ntfy $(incus exec "$ct" -- dpkg-query -W -f '${Version}' ntfy </dev/null)"

step "Configure"
low_ports
in_ct "Writing /etc/ntfy/server.yml and starting ntfy" '
  cat > /etc/ntfy/server.yml <<YML
# Written by "hs recipe ntfy". Reachable inside the home network only.
base-url: "$1"
listen-http: ":$2"
# keep messages for two days, so a phone that was offline still gets them
cache-file: "/var/cache/ntfy/cache.db"
cache-duration: "48h"
YML
  mkdir -p /var/cache/ntfy && chown ntfy:ntfy /var/cache/ntfy
  systemctl enable -q ntfy
  systemctl restart ntfy' "$(web)" "$PORT"
wait_page ntfy 'journalctl -u ntfy' --path /v1/health --ok --plain --tries 15 --every 1

step "Connect this server's notifications"
mkdir -p "$state"
# keep the topic across runs: the phone is subscribed to it
topic=$(sed -n 's|.*/||p' "$state/notify-url" 2>/dev/null | grep -E '^hs-[a-z0-9]+$' || true)
[ -n "$topic" ] || topic="hs-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
echo "$(web)/$topic" > "$state/notify-url"
bash "$scripts/notify.sh" --category ok "$(hostname): ntfy is set up" "Warnings about disks, pools and failed jobs arrive here from now on." >/dev/null
if curl -fsS -m 5 "$(web)/$topic/json?poll=1" | grep -q "ntfy is set up"; then
  ok "Test message sent and stored"
else
  fail "$(t 'The test message did not arrive at %s.' "$(web)/$topic")"
fi

declare_service ntfy ntfy ntfy private-ok Apps "Push messages"
box <<DONE
$(say "Done. On the phone:")
$(say '  1. Install the app "ntfy" (Android, iOS).')
$(t '  2. In its settings set the default server to   %s' "$(web)")
$(t '  3. Subscribe to the topic                       %s' "$topic")
$(docs_hint containers-and-apps)
DONE
