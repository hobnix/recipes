#!/usr/bin/env bash
# recipe: qBittorrent: torrent downloader that can only reach the internet through your VPN (gluetun)
# recipe.de: qBittorrent: Torrent-Downloader, der nur durch dein VPN ins Internet kommt (gluetun)
# kind: generic
# needs: docker share
# input: form
# ask: VPN_PROVIDER|VPN provider, as gluetun names it (mullvad, protonvpn, nordvpn, airvpn, ivpn, surfshark ...)|text|protonvpn|[a-z][a-z0-9 ._-]*|
# ask: VPN_TYPE|VPN protocol|choice:wireguard,openvpn|wireguard||
# ask: SERVER_COUNTRIES|VPN server countries, comma separated (empty: the provider chooses)|text|||
# ask: WG_KEY|WireGuard private key|secret|||VPN_TYPE=wireguard
# ask: WG_ADDR|WireGuard address from the provider's config (Address =, like 10.2.0.2/32)|text||[0-9a-fA-F:./,]+|VPN_TYPE=wireguard
# ask: OV_USER|OpenVPN user name|text||[^ ]+|VPN_TYPE=openvpn
# ask: OV_PASS|OpenVPN password|secret|||VPN_TYPE=openvpn
# uses: -
set -euo pipefail

# What it does: creates the container "qbittorrent" with Docker inside and runs ONE compose project:
#   gluetun       the VPN client (WireGuard or OpenVPN, your provider). It owns the network of the project.
#   qbittorrent   linuxserver.io image, network_mode "service:gluetun": it has no network of its own, so when the
#                 tunnel is down it has no connection at all (the kill switch is the construction, not a setting).
#   web page      qBittorrent's page is published by gluetun on the container's address (port 80 by default);
#                 gluetun's firewall lets the home network (setting LAN) talk to it and nothing else out of the tunnel.
#   downloads     /media/downloads/torrents on the share "media" (the one of Jellyfin, Radarr and Sonarr, same path
#                 /media everywhere): Radarr and Sonarr move a finished torrent into the library by a hard link, so it
#                 seeds on without a second copy. A user "qbittorrent" is mapped 1:1 to the share's owner.
#   unfinished    /var/tmp/qbt-incomplete inside the container (SSD pool), the backup skips /var/tmp.
#   VPN account   typed at the first run (provider name, WireGuard key + address, or OpenVPN user + password) and written
#                 into /opt/qbittorrent/gluetun.env inside the container (root only, never on the server itself).
#   backup        `hs backup ct qbittorrent on` is switched on (the file holds your VPN login).
# qBittorrent's page has a login of its own but must never get a Zoraxy rule.
# Not set by the recipe: port forwarding of the VPN (gluetun.env, see the guide).
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
#   (RECIPE_SKIP_PULL also skips the VPN questions and does not start anything)
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-qbittorrent}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 2048 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  say "  give it the tunnel device /dev/net/tun (gluetun needs it)"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media"
  say "  ask for your VPN provider and account (WireGuard or OpenVPN) and keep it inside the container"
  say "  start gluetun and qBittorrent in one compose project: qBittorrent has no network outside the VPN"
  say "  open qBittorrent's page (asks for the port, default 80), downloads in /media/downloads/torrents"
  say "  make a push topic of its own and put the container in the nightly backup"
  exit 0
fi

port_setting "qBittorrent" 8080
setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
setting VPN_PROVIDER "VPN provider, as gluetun names it (mullvad, protonvpn, nordvpn, airvpn, ivpn, surfshark ...)" protonvpn protonvpn "[a-z][a-z0-9 ._-]*"
setting VPN_TYPE "VPN protocol: wireguard or openvpn" wireguard wireguard "wireguard|openvpn"
setting SERVER_COUNTRIES "VPN server countries, comma separated (empty: the provider chooses)" "" "" ".*"
setting LAN "Networks of your home that may open qBittorrent's page, comma separated" "10.0.0.0/8,192.168.0.0/16" "10.0.0.0/8,192.168.0.0/16" "[0-9./,]+"
share=$SHARE
ensure_container "$ct" 2048 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"

step "Tunnel device"
if incus config device get "$ct" tun path >/dev/null 2>&1; then
  ok "/dev/net/tun is in the container already"
else
  incus config device add "$ct" tun unix-char path=/dev/net/tun >/dev/null
  ok "/dev/net/tun added to the container"
fi

media_storage qbittorrent
incus exec "$ct" -- su -s /bin/sh qbittorrent -c 'mkdir -p /media/downloads/torrents' </dev/null ||
  fail "$(t "'%s' can't write to /media. Look at the storage of '%s' in: hs ct list" qbittorrent "$ct")"
install_docker

step "VPN account"
# The account lives in gluetun.env inside the container: a re-run keeps it. To change it, delete the file
# (incus exec <ct> -- rm /opt/qbittorrent/gluetun.env) and run the recipe again.
vpn_env=/opt/qbittorrent/gluetun.env
incus exec "$ct" -- mkdir -p /opt/qbittorrent </dev/null
if incus exec "$ct" -- test -s "$vpn_env" </dev/null; then
  ok "A VPN account is stored already, keeping it"
  note "$(t 'Another account? Delete it first: incus exec %s -- rm %s' "$ct" "$vpn_env")"
elif [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no VPN account asked"
elif ! interactive && [ -z "$(answer WG_KEY)$(answer OV_PASS)" ]; then
  fail "The VPN account is typed in. Run the recipe in a terminal, or use the web interface (Apps, Run)."
else
  note "$(t 'Provider %s, protocol %s. The values are in the account page or the config file of your provider.' "$VPN_PROVIDER" "$VPN_TYPE")"
  vpn_lines="VPN_SERVICE_PROVIDER=$VPN_PROVIDER
VPN_TYPE=$VPN_TYPE"
  [ -z "$SERVER_COUNTRIES" ] || vpn_lines="$vpn_lines
SERVER_COUNTRIES=$SERVER_COUNTRIES"
  if [ "$VPN_TYPE" = wireguard ]; then
    wg_key=$(answer WG_KEY); [ -n "$wg_key" ] || wg_key=$(ask_secret "WireGuard private key (not shown):")
    wg_addr=$(answer WG_ADDR); [ -n "$wg_addr" ] || wg_addr=$(ask "WireGuard address from the provider's config (Address =, like 10.2.0.2/32)")
    [ -n "$wg_key" ] && [ -n "$wg_addr" ] || fail "Key and address are both needed. Nothing was stored; run the recipe again."
    vpn_lines="$vpn_lines
WIREGUARD_PRIVATE_KEY=$wg_key
WIREGUARD_ADDRESSES=$wg_addr"
    unset wg_key
  else
    ov_user=$(answer OV_USER); [ -n "$ov_user" ] || ov_user=$(ask "OpenVPN user name")
    ov_pass=$(answer OV_PASS); [ -n "$ov_pass" ] || ov_pass=$(ask_secret "OpenVPN password (not shown):")
    [ -n "$ov_user" ] && [ -n "$ov_pass" ] || fail "User and password are both needed. Nothing was stored; run the recipe again."
    vpn_lines="$vpn_lines
OPENVPN_USER=$ov_user
OPENVPN_PASSWORD=$ov_pass"
    unset ov_pass
  fi
  # straight into the container; it is never written on the server itself
  printf '%s\n' "$vpn_lines" | incus exec "$ct" -- sh -c "umask 077; cat > $vpn_env"
  unset vpn_lines
  ok "$(t 'Stored in the container (%s, root only)' "$vpn_env")"
fi

step "qBittorrent"
# docker-compose.yml is written again at every run. The seed of qBittorrent's settings is written only when there is
# none yet, so a change in its page stays. (The key names of qBittorrent.conf are from memory: check Options -> Downloads.)
compose='mkdir -p /opt/qbittorrent/gluetun /opt/qbittorrent/config/qBittorrent /var/tmp/qbt-incomplete
  [ -e /opt/qbittorrent/gluetun.env ] || { umask 077; : > /opt/qbittorrent/gluetun.env; }
  cat > /opt/qbittorrent/docker-compose.yml.new <<YML
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    env_file: ["/opt/qbittorrent/gluetun.env"]
    environment:
      - TZ=$1
      - FIREWALL_OUTBOUND_SUBNETS=$5
    ports: ["$4:8080"]
    volumes: ["/opt/qbittorrent/gluetun:/gluetun"]
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
    environment:
      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002
      - WEBUI_PORT=8080
    volumes: ["/opt/qbittorrent/config:/config", "/media:/media", "/var/tmp/qbt-incomplete:/incomplete"]
YML
  mv /opt/qbittorrent/docker-compose.yml.new /opt/qbittorrent/docker-compose.yml
  if [ ! -e /opt/qbittorrent/config/qBittorrent/qBittorrent.conf ]; then
    cat > /opt/qbittorrent/config/qBittorrent/qBittorrent.conf <<"CONF"
[BitTorrent]
Session\DefaultSavePath=/media/downloads/torrents
Session\TempPathEnabled=true
Session\TempPath=/incomplete

[Preferences]
WebUI\Address=*
WebUI\Port=8080
CONF
  fi
  chown -R "$2:$3" /opt/qbittorrent/config /opt/qbittorrent/gluetun /var/tmp/qbt-incomplete
  cd /opt/qbittorrent && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings (port, user, networks)" "$compose" "$tz" "${ids%%:*}" "${ids##*:}" "$PORT" "$LAN"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, qBittorrent not started"
else
  in_ct "Downloading gluetun and qBittorrent" 'cd /opt/qbittorrent && docker compose pull -q'
  in_ct "Starting the VPN and qBittorrent" 'cd /opt/qbittorrent && docker compose up -d --remove-orphans' ||
    fail "$(t 'The VPN did not come up, so qBittorrent was not started. Look at: incus exec %s -- docker logs gluetun --tail 30   (wrong key, address or provider name?)' "$ct")"
  wait_page qBittorrent "docker compose -f /opt/qbittorrent/docker-compose.yml logs --tail 50"

  step "Kill switch"
  # The address the internet sees from inside the project must not be the server's own.
  vpn_ip=$(incus exec "$ct" -- docker exec gluetun wget -qO- -T 10 https://api.ipify.org </dev/null 2>/dev/null || true)
  own_ip=$(incus exec "$ct" -- curl -s -m 10 https://api.ipify.org </dev/null 2>/dev/null || true)
  if [ -n "$vpn_ip" ] && [ "$vpn_ip" != "$own_ip" ]; then
    ok "$(t 'Torrent traffic leaves through the VPN (address %s, not your own)' "$vpn_ip")"
  elif [ -n "$vpn_ip" ]; then
    warn "$(t 'The address seen from the tunnel (%s) is your own. Do not use qBittorrent: look at the VPN settings.' "$vpn_ip")"
  else
    warn "$(t 'Could not look up the address behind the VPN. Check it yourself: incus exec %s -- docker exec gluetun wget -qO- https://api.ipify.org' "$ct")"
  fi
fi

step "Backup"
media_backup ""
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

media_ntfy

recipe_facts web
declare_service qbittorrent qBittorrent qbittorrent never-public Apps "Torrents"
box <<DONE
$(say "No Zoraxy rule: it is for the home network only.")
$(say "The few clicks that cannot wait:")
$(say "  1. Log in as admin; the temporary password is in:  docker logs qbittorrent  (inside the container).")
$(say "     Then set your own: Tools -> Options -> Web UI.")
$(t '  2. Radarr and Sonarr: Settings -> Download Clients -> qBittorrent, host %s, port %s, category  movies  /  tv' "$ip" "$PORT")
$(t 'Push messages (Radarr/Sonarr: Settings -> Connect -> ntfy):  server %s   topic %s' "$ntfy_server" "$ntfy_topic")
$(docs_hint qbittorrent)
DONE
