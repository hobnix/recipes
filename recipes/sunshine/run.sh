#!/usr/bin/env bash
# recipe: Sunshine: play games from the server on the TV (Moonlight), with Steam and the NVIDIA card
# recipe.de: Sunshine: Spiele vom Server auf dem Fernseher spielen (Moonlight), mit Steam und der NVIDIA-Karte
# kind: generic
# needs: docker
# uses: gpu
set -euo pipefail

# What it does: creates the container "sunshine" with Docker inside and runs the image
# josh5/steam-headless in it: a desktop without a screen, Steam, and the Sunshine server
# (game streaming) on the server's NVIDIA card. The TV runs the app "Moonlight" and sees the
# container as a game PC. Linux and Proton games only; Windows games stay on the PC
#.
#   Steam library / settings   /opt/sunshine/home on the SSD pool, inside the container
#   input                      /dev/uinput and /dev/input are passed in (virtual keyboard,
#                              mouse, gamepads; the host loads the module uinput)
#   logins                     one random password for the desktop and the Sunshine web page,
#                              in /var/lib/hs/sunshine-admin (root only, vault-aware)
# Not run on the real server yet; the NVIDIA part (X server on the passed-in card) is the
# part most likely to need a second look.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1 (the
# compose file is written and checked, nothing downloaded or started).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-sunshine}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 8192 MB RAM limit) unless it exists, with a fixed address (.30-.39) if UniFi is connected (hs net setup)" "$ct")"
  say "  pass the NVIDIA card and the input devices (/dev/uinput, /dev/input) into the container"
  say "  install Docker and NVIDIA's container toolkit inside"
  say "  start Steam Headless with Sunshine from its image (several GB to download)"
  say "  keep the Steam library on the SSD pool (/opt/sunshine/home in the container)"
  exit 0
fi

# Parked (2026-10-10): the image josh5/steam-headless (v2, systemd as PID 1) does not start inside Docker inside an
# unprivileged Incus container, the older v1 image hangs in Xorg on the iGPU, and nobody reports an unprivileged Incus
# setup that works (see CLAUDE.md "Game streaming"). RECIPE_FORCE=1 runs it anyway, for trying again.
if [ -z "${RECIPE_FORCE:-}" ]; then
  warn "This recipe is parked: the Steam Headless container does not start inside an Incus container yet (details: CLAUDE.md, Game streaming). Stream from the PC itself instead (Sunshine on the PC, Moonlight on the other device). To try anyway: RECIPE_FORCE=1 hs recipe sunshine"
  exit 1
fi

[ -n "$(incus query /1.0/resources 2>/dev/null | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty' 2>/dev/null)" ] ||
  fail "This server has no NVIDIA card in use (gpu = \"nvidia\" in machine.toml). The recipe streams games rendered on that card."

ensure_container "$ct" 8192 --docker
fixed_address "$ct" 30 39
wait_internet "$ct"

step "Input devices"
need_restart=false
# the module is loaded at boot by configuration.nix; this covers a server not rebuilt yet
[ -e /dev/uinput ] || modprobe uinput 2>/dev/null || true
if [ ! -e /dev/uinput ]; then
  warn "The server has no /dev/uinput. Run  hs rebuild  (it loads the module), then  hs recipe sunshine  again. Mouse, keyboard and gamepads will not work until then."
else
  if ! incus config device get "$ct" uinput type >/dev/null 2>&1; then
    incus config device add "$ct" uinput unix-char source=/dev/uinput path=/dev/uinput mode=0666 >/dev/null
    incus config device add "$ct" input disk source=/dev/input path=/dev/input >/dev/null
    need_restart=true
  fi
  # No raw.lxc "devices.allow" rule for the input devices: one such line makes LXC deny every device
  # that is not listed (even /dev/null), and the container no longer boots. An earlier version of this recipe set one: take it out.
  if [ "$(incus config get "$ct" raw.lxc)" = "lxc.cgroup2.devices.allow = c 13:* rwm" ]; then
    incus config unset "$ct" raw.lxc
    need_restart=true
  fi
  ok "/dev/uinput and /dev/input are passed in"
fi

step "NVIDIA graphics card"
if [ "$(incus config get "$ct" nvidia.runtime)" = true ] && incus config device get "$ct" gpu type >/dev/null 2>&1; then
  ok "passed in already"
  if $need_restart; then
    spin "$(t "Restarting '%s'" "$ct")" incus restart "$ct"
    spin "Waiting for the container" bash -c "$wait_address" _ "$ct" "" 30
  fi
elif nvidia_gpu "$ct"; then       # restarts the container, which also activates the input devices
  ok "$(t "'%s' can see the NVIDIA card" "$ct")"
else
  fail "The NVIDIA card could not be passed into the container."
fi

install_docker
nvidia_docker || fail "Docker can't use the NVIDIA card. Look at the lines above."

step "Sunshine and Steam"
# one password for the desktop and Sunshine's web page; kept when it exists
if [ "$(secret_state "$state/sunshine-admin")" = locked ]; then
  secret_locked_exit
elif [ -s "$state/sunshine-admin" ]; then
  ok "$(t 'Kept as it is (password in %s/sunshine-admin)' "$state")"
else
  secret_prepare sunshine-admin "$state" || exit 1
  pw=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20 || true)
  ( umask 077; printf 'user: sunshine\npassword: %s\n' "$pw" > "$state/sunshine-admin" )
fi
pw=$(sed -n 's/^password: //p' "$state/sunshine-admin" | head -n1)

in_ct "Writing the settings" '
  mkdir -p /opt/sunshine/home && cd /opt/sunshine
  cat > docker-compose.yml.new <<YML
services:
  steam-headless:
    image: josh5/steam-headless:latest
    restart: unless-stopped
    network_mode: host
    ipc: host
    shm_size: 2g
    ulimits:
      nofile:
        soft: 1024
        hard: 524288
    cap_add: [NET_ADMIN, SYS_ADMIN, SYS_NICE]
    security_opt: ["seccomp:unconfined", "apparmor:unconfined"]
    hostname: sunshine
    devices:
      - /dev/fuse
      - /dev/uinput
    device_cgroup_rules:
      - "c 13:* rmw"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    environment:
      TZ: $2
      PUID: "1000"
      PGID: "1000"
      UMASK: "000"
      USER_PASSWORD: "$1"
      MODE: primary
      WEB_UI_MODE: vnc
      PORT_NOVNC_WEB: "8083"
      ENABLE_VNC_AUDIO: "true"
      ENABLE_STEAM: "true"
      STEAM_ARGS: -silent
      ENABLE_SUNSHINE: "true"
      SUNSHINE_USER: sunshine
      SUNSHINE_PASS: "$1"
      ENABLE_EVDEV_INPUTS: "true"
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: all
    volumes:
      - /opt/sunshine/home:/home/default:rw
      - /tmp/.X11-unix:/tmp/.X11-unix:rw
YML
  chmod 600 docker-compose.yml.new && mv docker-compose.yml.new docker-compose.yml
  docker compose config -q' "$pw" "$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Sunshine not started"
else
  in_ct "Downloading Steam Headless (several GB, this takes a while)" 'cd /opt/sunshine && docker compose pull -q'
  in_ct "Starting it" 'cd /opt/sunshine && docker compose up -d --remove-orphans'
  spin "Waiting for Sunshine to answer (the first start installs Steam and the driver parts)" \
    bash -c 'for _ in $(seq 1 180); do curl -ksS -m 3 -o /dev/null "https://$1:47990/" 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$ip" ||
    fail "$(t 'Sunshine does not answer at https://%s:47990 . Look at: incus exec %s -- docker compose -f /opt/sunshine/docker-compose.yml logs --tail 80' "$ip" "$ct")"
  if incus exec "$ct" -- docker compose -f /opt/sunshine/docker-compose.yml logs --tail 400 </dev/null 2>/dev/null | grep -qi 'nvenc'; then
    ok "Sunshine found the NVIDIA encoder (NVENC)"
  else
    warn "$(t 'No sign of NVENC in the log yet; Sunshine may be encoding on the CPU. Look at: incus exec %s -- docker compose -f /opt/sunshine/docker-compose.yml logs | grep -i -e nvenc -e encoder' "$ct")"
  fi
fi

box <<DONE
$(t 'Done. Sunshine web page (set-up only, never behind Zoraxy):  https://%s:47990' "$ip")
$(say "  1. The login is in  /var/lib/hs/sunshine-admin  (user and password).")
$(t '  2. On the TV: app "Moonlight", add the computer by address  %s ,' "$ip")
$(say "     it shows a PIN: enter it in the Sunshine web page under PIN.")
$(say "  3. The desktop with Steam (log in to Steam once, install games):")
$(t '     http://%s:8083  (same password)' "$ip")
$(say "A game PC at home can be added as a second entry: hs ext games add, hs ext games wake.")
$(docs_hint containers-and-apps)
DONE
