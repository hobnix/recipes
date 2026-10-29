#!/usr/bin/env bash
# recipe: cloudflared: the Cloudflare Tunnel that makes chosen services reachable from the internet
# recipe.de: cloudflared: der Cloudflare-Tunnel, der ausgewählte Dienste aus dem Internet erreichbar macht
# kind: personal
# needs: -
# input: form
# ask: TOKEN|Tunnel token (the long word starting with eyJ in the install command of the tunnel page; the whole command may be pasted)|secret|||
# uses: -
set -euo pipefail

# What it does: creates the container "cloudflared", installs cloudflared
# from Cloudflare's package source and runs it with your tunnel token.
# The tunnel only connects outwards; no port is opened on the router.
# The token is the one thing it has to ask for: you create the tunnel in the
# Cloudflare dashboard, which shows it. It is stored in the container only
# (/etc/cloudflared/token, readable by root).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-cloudflared}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (512 MB RAM limit) unless it exists, with a fixed address (.10 to .19) if UniFi is connected (hs net setup)" "$ct")"
  say "  install cloudflared inside"
  say "  ask for the tunnel token (unless it is stored already) and start the tunnel"
  exit 0
fi

ensure_container "$ct" 512
fixed_address "$ct" 10 19
wait_internet "$ct"

step "Install cloudflared"
if incus exec "$ct" -- sh -c 'command -v cloudflared' >/dev/null 2>&1 </dev/null; then
  ok "installed already"
else
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing curl" '$1 install -y -qq curl ca-certificates' "$apt_quick"
  in_ct "Adding the Cloudflare package source" '
    mkdir -p /etc/apt/keyrings
    curl -fsSL -m 60 https://pkg.cloudflare.com/cloudflare-public-v2.gpg -o /etc/apt/keyrings/cloudflared.gpg
    cat > /etc/apt/sources.list.d/cloudflared.sources <<SRC
Types: deb
URIs: https://pkg.cloudflare.com/cloudflared/
Suites: any
Components: main
Signed-By: /etc/apt/keyrings/cloudflared.gpg
SRC
    $1 update -qq' "$apt_quick"
  in_ct "Installing cloudflared" '$1 install -y -qq cloudflared' "$apt_quick"
fi
note "cloudflared $(incus exec "$ct" -- dpkg-query -W -f '${Version}' cloudflared </dev/null)"

step "Tunnel token"
if incus exec "$ct" -- test -s /etc/cloudflared/token </dev/null; then
  ok "A token is stored already, keeping it"
  note "$(t 'Another tunnel? Delete it first: incus exec %s -- rm /etc/cloudflared/token' "$ct")"
else
  note "Where it comes from: Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> Create a tunnel"
  note "(type Cloudflared). The page then shows an install command; the long word starting with"
  note '"eyJ" in it is the token. You can paste the whole command.'
  token=$(answer TOKEN)
  if [ -z "$token" ]; then
    interactive || fail "The tunnel token is typed in: run the recipe in a terminal, or use the web interface (Apps, Run)."
    token=$(ask_secret "Tunnel token (not shown):")
  fi
  token=${token##* }          # the whole command was pasted: the token is its last word
  [[ "$token" =~ ^[A-Za-z0-9_=-]{50,}$ ]] || fail "That does not look like a tunnel token. Nothing was stored; run the recipe again."
  # straight into the container; it is never written on the server itself
  printf '%s' "$token" | incus exec "$ct" -- sh -c 'umask 077; mkdir -p /etc/cloudflared; cat > /etc/cloudflared/token'
  unset token
  ok "Stored in the container (/etc/cloudflared/token, root only)"
fi

step "Start"
in_ct "Starting the tunnel with the system" '
  cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q cloudflared
  systemctl restart cloudflared' ||
  fail "$(t 'The tunnel did not start; most often the token is wrong. Delete it (incus exec %s -- rm /etc/cloudflared/token) and run the recipe again. Details: incus exec %s -- journalctl -u cloudflared -n 20' "$ct" "$ct")"
SPIN_SOFT=1 spin "Waiting for the connection to Cloudflare" \
  incus exec "$ct" -- sh -c 'for _ in $(seq 1 20); do journalctl -u cloudflared -b --no-pager | grep -q "Registered tunnel connection" && exit 0; sleep 1; done; exit 1' ||
  warn "$(t 'No connection confirmed yet. Look at: incus exec %s -- journalctl -u cloudflared -n 20' "$ct")"

zoraxy=$(address zoraxy 2>/dev/null || true)
recipe_facts
box <<DONE
$(say "In the Cloudflare dashboard, on the tunnel's page: Public Hostname -> Add")
$(t '  subdomain *  (and one without subdomain), your domain, service  HTTP  %s:80' "${zoraxy:-$(_tr '<address of zoraxy>')}")
$(docs_hint containers-and-apps)
DONE
