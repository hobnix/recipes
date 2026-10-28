#!/usr/bin/env bash
# recipe: Uptime Kuma: checks that your services answer, keeps a history and warns when one is down
# recipe.de: Uptime Kuma: prüft, ob deine Dienste antworten, führt einen Verlauf und warnt, wenn einer ausfällt
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "uptime-kuma", installs Uptime Kuma
# from its source (Node.js, no Docker), and starts it with the system.
# The checks themselves are added in its web page: the first visit creates
# the admin login there, so the recipe can't do that part.
# No Zoraxy rule: it is an admin page.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-uptime-kuma}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (1024 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Node.js and Uptime Kuma inside (/opt/uptime-kuma), started by systemd (asks for the port, default 80)"
  say "  list the addresses worth checking"
  exit 0
fi

port_setting "Uptime Kuma" 3001
ensure_container "$ct" 1024
fixed_address "$ct"
wait_internet "$ct"

step "Install Uptime Kuma"
if incus exec "$ct" -- sh -c 'test -f /opt/uptime-kuma/server/server.js && test -d /opt/uptime-kuma/dist' </dev/null 2>/dev/null; then
  ok "installed already"
else
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing Node.js and git" '$1 install -y -qq --no-install-recommends nodejs npm git ca-certificates curl iputils-ping' "$apt_quick"
  in_ct "Downloading Uptime Kuma" 'rm -rf /opt/uptime-kuma; git clone -q https://github.com/louislam/uptime-kuma.git /opt/uptime-kuma'
  # checks out the latest release, installs what it needs, downloads the web page
  in_ct "Installing it (a few minutes)" 'cd /opt/uptime-kuma && npm run setup'
fi
in_ct "Starting it with the system" '
  cat > /etc/systemd/system/uptime-kuma.service <<UNIT
[Unit]
Description=Uptime Kuma
After=network-online.target

[Service]
WorkingDirectory=/opt/uptime-kuma
ExecStart=/usr/bin/node server/server.js
Restart=on-failure
Environment=NODE_ENV=production
Environment=UPTIME_KUMA_PORT=$1

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q uptime-kuma
  systemctl restart uptime-kuma' "$PORT"
note "Uptime Kuma $(incus exec "$ct" -- git -C /opt/uptime-kuma describe --tags </dev/null 2>/dev/null || _tr "installed")"
wait_page 'Uptime Kuma' 'journalctl -u uptime-kuma' --plain --tries 60

# what is worth a check: every running instance with its address
step "Addresses worth checking"
incus list -f json | jq -r --arg me "$ct" '.[] | select(.status == "Running" and .name != $me)
  | [ .name, ((.state.network // {}) | (.eth0 // .enp5s0 // {}) | (.addresses // []) | map(select(.family == "inet")) | .[0].address // "-") ] | @tsv' |
  while IFS=$'\t' read -r n a; do kv "$n" "$a"; done
host_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
kv "$(hostname) (server)" "$host_ip"

notify=$(cat "$state/notify-url" /etc/hs/notify-url 2>/dev/null | head -n1 || true)
if [ -n "$notify" ]; then where=$(t 'server and topic as in  %s' "$notify")
else where=$(_tr "your ntfy server and topic (hs recipe ntfy sets one up)"); fi
declare_service uptime-kuma "Uptime Kuma" uptime-kuma never-public Monitoring "Service checks"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say '  1. The first visit asks which database to use: choose "SQLite" (nothing else to install).')
$(say "     Then it asks for a user name and password: that becomes the admin login.")
$(say '  2. Settings -> Notifications -> "Setup Notification", type "Ntfy":')
       $where
$(say "     Then it warns on the same channel as this server.")
$(docs_hint containers-and-apps)
DONE
