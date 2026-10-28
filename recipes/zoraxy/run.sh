#!/usr/bin/env bash
# recipe: Zoraxy: the reverse proxy that sends each public name to the right container
# recipe.de: Zoraxy: der Reverse-Proxy, der jeden öffentlichen Namen zum richtigen Container schickt
# kind: personal
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "zoraxy" and installs Zoraxy (one
# program from its GitHub releases, started by systemd).
#   port 80     what the Cloudflare tunnel sends its traffic to
#   port 8000   the admin page, for the home network only
# Encryption ends at Cloudflare, so Zoraxy speaks plain HTTP.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-zoraxy}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (2048 MB RAM limit) unless it exists, with a fixed address (.10 to .19) if UniFi is connected (hs net setup)" "$ct")"
  say "  install the newest Zoraxy inside (/opt/zoraxy), started by systemd; an existing one is updated, its rules are kept"
  exit 0
fi

# not 80: that is where the proxy itself listens
setting PORT "$(_tr "Port of Zoraxy's admin page (not 80, the proxy itself listens there)")" 8000 8000 "$a_port" 80
ensure_container "$ct" 2048
fixed_address "$ct" 10 19
wait_internet "$ct"

step "Install Zoraxy"
in_ct "Installing curl" 'command -v curl >/dev/null || { $1 update -qq; $1 install -y -qq curl ca-certificates; }' "$apt_quick"
# the program is replaced, its folder with the rules (conf, sys.db) stays
in_ct "Downloading the newest Zoraxy" '
  mkdir -p /opt/zoraxy && cd /opt/zoraxy
  curl -fsSL -m 300 -o zoraxy.new https://github.com/tobychui/zoraxy/releases/latest/download/zoraxy_linux_amd64
  chmod +x zoraxy.new
  ./zoraxy.new -version >/dev/null
  systemctl stop zoraxy 2>/dev/null || true
  mv zoraxy.new zoraxy'
in_ct "Starting it with the system" '
  cat > /etc/systemd/system/zoraxy.service <<UNIT
[Unit]
Description=General purpose request proxy and forwarding tool
After=syslog.target network-online.target

[Service]
ExecStart=/opt/zoraxy/./zoraxy -port=:$1
WorkingDirectory=/opt/zoraxy/
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q zoraxy
  systemctl restart zoraxy' "$PORT"
note "$(incus exec "$ct" -- /opt/zoraxy/zoraxy -version </dev/null 2>/dev/null | head -n1)"
wait_page Zoraxy 'journalctl -u zoraxy -n 30' --plain --tries 30 --every 1

declare_service zoraxy Zoraxy zoraxy never-public Administration "Reverse proxy: which address goes where"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  1. The first visit creates the admin account.")
$(say "  2. HTTP Proxy -> New Proxy Rule, one per service you want reachable from outside (matching name, target address:port).")
$(say "Every rule here is reachable from the whole internet. Never add one for an admin page")
$(say "(Incus, this page, Arcane, Grafana, Uptime Kuma, Homepage).")
$(docs_hint containers-and-apps)
DONE
