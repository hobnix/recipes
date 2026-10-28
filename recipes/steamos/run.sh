#!/usr/bin/env bash
# recipe: SteamOS-like Steam container: play from the server on the TV or phone with Steam Remote Play, on the NVIDIA card
# recipe.de: Steam-Container wie SteamOS: Spiele vom Server auf Fernseher oder Handy spielen (Steam Remote Play), mit der NVIDIA-Karte
# kind: generic
# needs: -
# uses: gpu
set -euo pipefail

# What it does: creates the container "steamos" (Debian, NO Docker) and sets up what SteamOS
# does on a console, as far as a container allows: a desktop without a screen (Xorg on the
# server's NVIDIA card with a virtual 1920x1080 monitor), Steam in Big Picture mode, a virtual
# sound card. Steam encodes the picture with NVENC itself: the TV or phone runs the app
# "Steam Link" (or another PC runs Steam) and plays through Steam Remote Play. No Sunshine,
# no Moonlight. Real SteamOS is a bootable image and can't run in a container.
#   the card     only the NVIDIA card is passed in (nvidia_gpu), the iGPU has no node in the
#                container: the parked sunshine recipe hung in Xorg probing it
#   input        /dev/uinput and /dev/input are passed in (Steam makes virtual gamepads)
#   units        hs-xorg, hs-steam (user "steam"), hs-vnc (the desktop, for the first Steam login)
#   login        one random 8-character password for the VNC desktop, in
#                /var/lib/hs/steamos-admin (root only, vault-aware); VNC uses only 8 characters
#   library      /home/steam/.local/share/Steam, on the SSD pool, inside the container
# Linux and Proton games only; Windows games stay on the PC.
# Not run on the real server yet. Most likely to need a second look: Xorg on the passed-in
# card (the driver module nvidia_drv.so must be among the files Incus mounts) and the 32-bit
# NVIDIA libraries (the host needs hardware.graphics.enable32Bit for those).
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1 (the files
# are written, no package or Steam download, nothing started).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-steamos}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Debian, no Docker, 8192 MB RAM limit) unless it exists, with a fixed address (.30-.39) if UniFi is connected (hs net setup)" "$ct")"
  say "  pass the NVIDIA card and the input devices (/dev/uinput, /dev/input) into the container"
  say "  install Xorg, Steam (from Valve), a window manager, sound and a VNC server inside"
  say "  start Xorg on the NVIDIA card with a virtual monitor, and Steam in Big Picture mode"
  say "  keep the Steam library on the SSD pool (/home/steam in the container)"
  exit 0
fi

pci=$(incus query /1.0/resources 2>/dev/null | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty' 2>/dev/null || true)
[ -n "$pci" ] ||
  fail "This server has no NVIDIA card in use (gpu = \"nvidia\" in machine.toml). The recipe streams games rendered on that card."
# 0000:01:00.0 -> PCI:1:0:0 (Xorg wants decimal bus, device, function)
IFS=':.' read -r _ bus dev fn <<<"$pci"
busid="PCI:$((16#$bus)):$((16#$dev)):$((16#$fn))"

ensure_container "$ct" 8192
fixed_address "$ct" 30 39
wait_internet "$ct"

step "Input devices"
need_restart=false
# the module is loaded at boot by configuration.nix; this covers a server not rebuilt yet
[ -e /dev/uinput ] || modprobe uinput 2>/dev/null || true
if [ ! -e /dev/uinput ]; then
  warn "$(t 'The server has no /dev/uinput. Run  hs rebuild  (it loads the module), then  hs recipe steamos  again. Gamepads will not work until then.')"
else
  if ! incus config device get "$ct" uinput type >/dev/null 2>&1; then
    incus config device add "$ct" uinput unix-char source=/dev/uinput path=/dev/uinput mode=0666 >/dev/null
    incus config device add "$ct" input disk source=/dev/input path=/dev/input >/dev/null
    need_restart=true
  fi
  # No raw.lxc "devices.allow" line: it makes LXC deny every device that is not listed and the container no longer boots.
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

step "Login"
# one password for the VNC desktop; kept when it exists. VNC looks at the first 8 characters only.
if [ "$(secret_state "$state/steamos-admin")" = locked ]; then
  secret_locked_exit
elif [ -s "$state/steamos-admin" ]; then
  ok "$(t 'Kept as it is (password in %s/steamos-admin)' "$state")"
else
  secret_prepare steamos-admin "$state" || exit 1
  pw=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8 || true)
  ( umask 077; printf 'user: steam\npassword: %s\n' "$pw" > "$state/steamos-admin" )
  ok "$(t 'Password written to %s/steamos-admin' "$state")"
fi
pw=$(sed -n 's/^password: //p' "$state/steamos-admin" | head -n1 || true)

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no packages, Steam not downloaded"
else
  in_ct "Installing Xorg, sound and the 32-bit libraries" '
    dpkg --add-architecture i386
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl sudo dbus-x11 \
      xserver-xorg-core x11-xserver-utils xdotool openbox x11vnc \
      pulseaudio pulseaudio-utils mesa-utils mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
      libgl1 libgl1:i386 libvulkan1 libvulkan1:i386 fonts-dejavu-core
    id steam >/dev/null 2>&1 || useradd -m -s /bin/bash -G video,render,audio,input steam'
  in_ct "Downloading Steam (from Valve)" '
    echo "steam steam/question select I AGREE" | debconf-set-selections
    echo "steam steam/license note" | debconf-set-selections
    curl -fsSL -o /tmp/steam.deb https://repo.steampowered.com/steam/archive/stable/steam_latest.deb
    apt-get install -y -qq /tmp/steam.deb
    rm -f /tmp/steam.deb
    # the packages Steam would ask for at its first start (steamdeps, through polkit: nobody to type the password)
    apt-get update -qq
    apt-get install -y -qq libc6 libc6:i386 libegl1 libegl1:i386 libgbm1 libgbm1:i386       libgl1-mesa-dri libgl1-mesa-dri:i386 libgl1 libgl1:i386 steam-libs-amd64 steam-libs-i386'
fi

step "Xorg driver of the NVIDIA card"
# Incus mounts the driver's libraries, not its Xorg parts (nvidia_drv.so, the GLX extension). They are copied from the
# server, the ones of the driver that is running (a copy, not a mount: a mount of a store path stops the container from
# starting once a driver update removes that path). After a driver update: run this recipe again.
xdir=$(dirname "$(dirname "$(readlink -f "$(command -v nvidia-smi)")")")/lib/xorg/modules
if [ ! -e "$xdir/drivers/nvidia_drv.so" ] || [ ! -e "$xdir/extensions/libglxserver_nvidia.so" ]; then
  fail "The server has no Xorg driver for the NVIDIA card (nvidia_drv.so). services.xserver.videoDrivers must contain nvidia (gpu = \"nvidia\" in machine.toml)."
fi
incus exec "$ct" -- mkdir -p /opt/hs-nvidia-xorg/drivers /opt/hs-nvidia-xorg/extensions </dev/null
incus file push "$xdir/drivers/nvidia_drv.so" "$ct/opt/hs-nvidia-xorg/drivers/nvidia_drv.so" >/dev/null
incus file push "$xdir/extensions/libglxserver_nvidia.so" "$ct/opt/hs-nvidia-xorg/extensions/libglxserver_nvidia.so" >/dev/null
incus exec "$ct" -- ln -sf libglxserver_nvidia.so /opt/hs-nvidia-xorg/extensions/libglx.so </dev/null
ok "Copied nvidia_drv.so and the GLX extension from the server"

in_ct "Writing the desktop, sound and the units" '
  cat > /etc/X11/xorg-hs.conf <<XORG
Section "Files"
  ModulePath "/opt/hs-nvidia-xorg"
  ModulePath "/usr/lib/xorg/modules"
EndSection
Section "ServerFlags"
  Option "AllowEmptyInput" "true"
  Option "AutoAddDevices" "false"
  Option "AutoEnableDevices" "false"
  Option "AutoAddGPU" "false"
  Option "DontVTSwitch" "true"
EndSection
Section "Device"
  Identifier "gpu0"
  Driver "nvidia"
  BusID "$1"
  Option "AllowEmptyInitialConfiguration" "true"
  Option "ConnectedMonitor" "DFP-0"
  Option "Monitor-DFP-0" "virtual"
  Option "ModeValidation" "NoDFPNativeResolutionCheck,NoEdidModeCheck,NoMaxPClkCheck,NoVertRefreshCheck,NoHorizSyncCheck,NoWidthAlignmentCheck"
EndSection
Section "Monitor"
  Identifier "virtual"
  HorizSync 30-200
  VertRefresh 24-144
  Modeline "1920x1080_60" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
EndSection
Section "Screen"
  Identifier "screen0"
  Device "gpu0"
  Monitor "virtual"
  DefaultDepth 24
  SubSection "Display"
    Depth 24
    Virtual 1920 1080
    Modes "1920x1080_60"
  EndSubSection
EndSection
XORG

  cat > /usr/local/bin/hs-steam-session <<SESSION
#!/bin/bash
# Steam in Big Picture on the virtual screen (started by hs-steam.service, user steam)
# -cef-disable-gpu*: with the GPU compositor the Steam web UI floods X with GLXBadPixmap errors and the screen stays black; streaming still encodes with NVENC
export DISPLAY=:0
until xset q >/dev/null 2>&1; do sleep 1; done
pulseaudio --start --exit-idle-time=-1 --log-target=syslog || true
pactl load-module module-null-sink sink_name=hs_sink >/dev/null 2>&1 || true
pactl set-default-sink hs_sink >/dev/null 2>&1 || true
openbox &
exec steam -tenfoot -cef-disable-gpu -cef-disable-gpu-compositing
SESSION
  chmod 755 /usr/local/bin/hs-steam-session

  # no key or mouse bindings in the window manager: a key from the TV (Print Screen) must not start programs or open menus
  install -d -o steam -g steam /home/steam/.config/openbox
  perl -0pe "s|<keyboard>.*?</keyboard>|<keyboard/>|s; s|<mouse>.*?</mouse>|<mouse/>|s" /etc/xdg/openbox/rc.xml > /home/steam/.config/openbox/rc.xml
  chown steam:steam /home/steam/.config/openbox/rc.xml

  install -d -o steam -g steam -m 700 /home/steam/.vnc
  x11vnc -storepasswd "$2" /home/steam/.vnc/passwd >/dev/null 2>&1
  chown steam:steam /home/steam/.vnc/passwd

  cat > /etc/systemd/system/hs-xorg.service <<UNIT
[Unit]
Description=Xorg on the NVIDIA card with a virtual monitor (hs recipe steamos)
After=hs-nvidia-libs.service

[Service]
ExecStart=/usr/lib/xorg/Xorg :0 -config /etc/X11/xorg-hs.conf -noreset -novtswitch -sharevts -nolisten tcp -ac
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/hs-steam.service <<UNIT
[Unit]
Description=Steam in Big Picture mode (hs recipe steamos)
Requires=hs-xorg.service
After=hs-xorg.service

[Service]
User=steam
Environment=DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000
PermissionsStartOnly=true
ExecStartPre=/usr/bin/install -d -o steam -g steam -m 700 /run/user/1000
ExecStart=/usr/local/bin/hs-steam-session
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/hs-vnc.service <<UNIT
[Unit]
Description=VNC view of the desktop, for the first Steam login (hs recipe steamos)
Requires=hs-xorg.service
After=hs-xorg.service

[Service]
User=steam
ExecStart=/usr/bin/x11vnc -display :0 -rfbauth /home/steam/.vnc/passwd -rfbport 5900 -forever -shared -noxdamage
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload' "$busid" "$pw"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing started"
else
  in_ct "Starting the desktop and Steam" 'systemctl enable -q hs-xorg.service hs-steam.service hs-vnc.service; systemctl restart hs-xorg.service; sleep 3; systemctl restart hs-steam.service hs-vnc.service'
  if spin "Waiting for the virtual screen" incus exec "$ct" -- bash -c 'for _ in $(seq 1 30); do DISPLAY=:0 xset q >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'; then
    if incus exec "$ct" -- bash -c 'DISPLAY=:0 glxinfo -B 2>/dev/null | grep -qi "NVIDIA"' </dev/null; then
      ok "The desktop renders on the NVIDIA card"
    else
      warn "$(t 'The desktop is up but does not render on the NVIDIA card. Look at: incus exec %s -- bash -c "DISPLAY=:0 glxinfo -B"' "$ct")"
    fi
  else
    fail "$(t 'Xorg did not start on the NVIDIA card. Look at: incus exec %s -- journalctl -u hs-xorg -n 60 ; hs recipe steamos copies nvidia_drv.so from the server; run it again after a driver update.' "$ct")"
  fi
  incus exec "$ct" -- bash -c 'ls /usr/lib/i386-linux-gnu/ 2>/dev/null | grep -q "libGLX_nvidia\|libnvidia-glcore"' </dev/null ||
    warn "The 32-bit NVIDIA libraries are missing: Steam draws its window in software and 32-bit games fall back to the CPU. Set hardware.graphics.enable32Bit = true on the server, rebuild and restart the container."
fi

recipe_facts
box <<DONE
$(say "Steam is running on the server's NVIDIA card. Log in to Steam once:")
$(t '  1. Open a VNC viewer at  %s:5900  (login in /var/lib/hs/steamos-admin, password only).' "$ip")
$(say "     Sign in to Steam, then Steam -> Settings -> Remote Play -> Enable Remote Play.")
$(say "  2. On the TV or phone: app \"Steam Link\", sign in with the same account. If the")
$(t '     server is not found (another network), choose "Other computer" and enter  %s .' "$ip")
$(say "     Steam Link shows a PIN: type it on the VNC desktop.")
$(say "  3. Games are installed from the desktop (Linux and Proton, Steam Play on).")
$(say "The VNC port 5900 is an admin door: never a Zoraxy rule. Stop it after the first login:")
$(t '     incus exec %s -- systemctl disable --now hs-vnc' "$ct")
$(docs_hint containers-and-apps)
DONE
