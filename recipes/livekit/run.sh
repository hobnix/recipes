#!/usr/bin/env bash
# recipe: LiveKit: voice and video calls for Matrix (Element Call, Cinny), media through the VPS
# recipe.de: LiveKit: Sprach- und Videoanrufe für Matrix (Element Call, Cinny), Medien über den VPS
# kind: personal
# needs: docker tailscale
# uses: -
set -euo pipefail

# What it does: creates the container "livekit" with Docker and Tailscale and starts two
# programs in it (host network): the LiveKit server (the media relay, SFU) and lk-jwt-service
# (gives a Matrix user a LiveKit ticket after checking the login with the homeserver).
# Synapse advertises them to clients (hs recipe synapse, "Calls"), so Cinny stops saying
# "Your homeserver does not support calling".
# The media (7881/tcp and a UDP range) does not go through Zoraxy: the VPS (repo proxyserver,
# rtcIp / rtcTcp / rtcUdp in its machine.nix) forwards it over Tailscale, like the game ports,
# and LiveKit tells clients the VPS address. Signalling (wss) and the ticket service are two
# Zoraxy rules (one host each, both fine to be public: nothing works without a Matrix login).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-livekit}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (1024 MB RAM limit) with Docker unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Tailscale inside and sign it in (you open a link): the VPS reaches the media ports through it"
  say "  ask for the public address of the VPS and the two host names (signalling, ticket service)"
  say "  run livekit-server and lk-jwt-service with Docker (/opt/livekit), with a random API key"
  say "  print the Zoraxy rules, the proxyserver machine.nix lines and the Tailscale ACL ports to set"
  exit 0
fi

setting PUBLIC_IP "Public IPv4 address of the VPS (the media goes through it)" "" "" "([0-9]{1,3}[.]){3}[0-9]{1,3}"
[ -n "$PUBLIC_IP" ] || fail "The public address of the VPS is needed: RECIPE_PUBLIC_IP=<address> hs recipe livekit"
# The host names are built from the Matrix server name: the one Synapse was set up with, when that is a
# real domain (not *.lan), else it has to be typed.
syn_name=$(sed -n 's/^SERVER_NAME=//p' "$state/recipe-synapse.conf" 2>/dev/null | tail -n1 || true)
case "$syn_name" in *.lan|*.local|*.home|*.internal) syn_name= ;; esac
setting MATRIX_SERVER "Matrix server name that may get tickets (the part after the colon in @user:name)" "$syn_name" "$syn_name" "[A-Za-z0-9][A-Za-z0-9.-]*"
[ -n "$MATRIX_SERVER" ] || fail "The Matrix server name is needed (your domain, e.g. example.com): RECIPE_MATRIX_SERVER=<name> hs recipe livekit"
setting SFU_HOST "Public host name for the signalling (wss, Zoraxy rule to port 7880)" "sfu.$MATRIX_SERVER" "sfu.$MATRIX_SERVER" "[A-Za-z0-9][A-Za-z0-9.-]*"
setting JWT_HOST "Public host name for the ticket service (Zoraxy rule to port 8080)" "rtc.$MATRIX_SERVER" "rtc.$MATRIX_SERVER" "[A-Za-z0-9][A-Za-z0-9.-]*"
setting UDP_FIRST "First UDP media port" 50000 50000 "$a_port"
setting UDP_LAST "Last UDP media port (about 5 per call participant)" 50100 50100 "$a_port"
[ "$UDP_FIRST" -lt "$UDP_LAST" ] || fail "The last UDP port must be higher than the first."

ensure_container "$ct" 1024 --docker
fixed_address "$ct"
wait_internet "$ct"

ct_tailscale
[ -z "$ts_ip" ] || ok "$(t 'Tailscale address: %s' "$ts_ip")"

install_docker

step "LiveKit"
# the key pair is made once; running the recipe again keeps it (calls in progress survive)
in_ct "Writing the configuration" '
  mkdir -p /opt/livekit
  if [ ! -s /opt/livekit/.env ]; then
    ( umask 077
      printf "LK_KEY=hs%s\nLK_SECRET=%s\n" "$(openssl rand -hex 6)" "$(openssl rand -hex 24)" > /opt/livekit/.env )
  fi
  . /opt/livekit/.env
  cat > /opt/livekit/livekit.yaml <<YAML
port: 7880
rtc:
  tcp_port: 7881
  port_range_start: $3
  port_range_end: $4
  # the address clients are told: the VPS, which forwards these ports over Tailscale
  node_ip: $1
  use_external_ip: false
keys:
  $LK_KEY: $LK_SECRET
YAML
  chmod 600 /opt/livekit/livekit.yaml
  cat > /opt/livekit/compose.yaml <<YAML
services:
  livekit:
    image: livekit/livekit-server:latest
    command: --config /etc/livekit.yaml
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml:ro
  jwt:
    image: ghcr.io/element-hq/lk-jwt-service:latest
    network_mode: host
    restart: unless-stopped
    environment:
      LIVEKIT_URL: wss://$2
      LIVEKIT_KEY: $LK_KEY
      LIVEKIT_SECRET: $LK_SECRET
      LIVEKIT_JWT_PORT: "8080"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: $5
YAML
  chmod 600 /opt/livekit/compose.yaml' "$PUBLIC_IP" "$SFU_HOST" "$UDP_FIRST" "$UDP_LAST" "$MATRIX_SERVER"
in_ct "Starting it (downloads the images)" 'cd /opt/livekit && docker compose pull -q && docker compose up -d --remove-orphans'
spin "Waiting for it to answer" bash -c 'for _ in $(seq 1 60); do
  curl -fsS -m 3 -o /dev/null "http://$1:7880/" 2>/dev/null && curl -s -m 3 -o /dev/null "http://$1:8080/" 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$ip" ||
  fail "$(t 'LiveKit does not answer at %s. Look at: incus exec %s -- docker compose -f /opt/livekit/compose.yaml logs' "$ip" "$ct")"

box <<DONE
$(say "Done. LiveKit runs, three things are still yours:")
$(t "  1. Zoraxy rules (both with WebSocket support; nothing else of this container, never a rule for another port):")
$(t "       %s  ->  http://%s:7880      (signalling)" "$SFU_HOST" "$ip")
$(t "       %s  ->  http://%s:8080      (ticket service)" "$JWT_HOST" "$ip")
$(t "  2. proxyserver machine.nix:  rtcIp = \"%s\";  rtcTcp = [ \"7881\" ];  rtcUdp = [ \"%s-%s\" ];" "${ts_ip:-<tailscale ip>}" "$UDP_FIRST" "$UDP_LAST")
$(say "     and the same ports for tag:vps in the Tailscale ACL, then nixos-rebuild switch on the VPS.")
$(t "  3. hs recipe synapse  (asks for the ticket service address https://%s and advertises it to clients)" "$JWT_HOST")
$(docs_hint containers-and-apps)
DONE
