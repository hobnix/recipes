#!/usr/bin/env bash
# recipe: Home Assistant, smart home control in its own virtual machine (Home Assistant OS)
# recipe.de: Home Assistant, Smart-Home-Steuerung in einer eigenen virtuellen Maschine (Home Assistant OS)
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: downloads the official Home Assistant OS image (GitHub release),
# imports it as an Incus image, creates the virtual machine "homeassistant"
# from it (UEFI without secure boot, as HAOS needs), optionally passes a USB
# stick (Zigbee/Z-Wave) in, starts it and waits for the web page on port 8123.
# HAOS has no shell for `incus exec`, but Incus reports its address (enp5s0), so
# the stock address helpers of _lib.sh work; UniFi is only used to reserve it.
# No Zoraxy rule: Home Assistant is an admin page (reach it at home or through Tailscale).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-homeassistant}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  download the latest Home Assistant OS image (about 400 MB) and import it as an Incus image")"
  printf '%s\n' "$(t "  create the virtual machine '%s' (4096 MB RAM, 2 CPUs, 32 GB disk, asks) unless it exists" "$ct")"
  say "  optionally pass a USB device (Zigbee/Z-Wave stick) into it"
  say "  reserve its address in UniFi, if UniFi is connected (hs net setup)"
  say "  wait for the web page on port 8123 (the first start takes 10 to 20 minutes)"
  exit 0
fi

unifi=false
if [ "$(secret_state "$state/unifi")" = locked ]; then vault_locked_note >&2; exit 1; fi
[ ! -r "$state/unifi" ] || unifi=true

# ── Preferences (first setup only) ──
if ! $existed; then
  networks=$(incus profile list -f csv -c n | grep -vx default | tr '\n' ' ')
  VLAN=default
  if [ "$(wc -w <<<"$networks")" -gt 1 ]; then
    setting VLAN "$(t "Network (VLAN) for '%s': default, or one of: %s" "$ct" "$networks")" default default "default|${networks// /|}"
  fi
  setting RAM "Memory in MB" 4096 4096 "$a_number"
  setting CPU "Number of CPUs" 2 2 "$a_number"
  setting DISK "Disk size in GB (32 or more)" 32 32 "[3-9][0-9]|[1-9][0-9]{2,}"
  usb=$(incus query /1.0/resources 2>/dev/null | jq -r '(.usb.devices // [])[] | select(.vendor_id != "1d6b")
    | [.vendor_id, .product_id, ((.vendor // "") + " " + (.product // ""))] | @tsv' || true)
  if [ -n "$usb" ] && { interactive || [ -n "${RECIPE_USB:-}" ]; }; then
    if interactive && [ -z "${RECIPE_USB:-}" ]; then
      step "USB devices of the server"
      while IFS=$'\t' read -r v p n; do kv "$v:$p" "$n"; done <<<"$usb"
    fi
    setting USB "USB stick for Home Assistant (vendor:product from the list, or none)" none none 'none|[0-9a-f]{4}:[0-9a-f]{4}'
  else
    USB=none
  fi
fi

# ── The virtual machine ──
if ! incus info "$ct" >/dev/null 2>&1; then
  step "Home Assistant OS image"
  work=$(mktemp -d /var/tmp/hs-haos.XXXXXX)
  trap 'rm -rf "$work"' EXIT
  ver=${RECIPE_VERSION:-}
  if [ -z "$ver" ]; then
    ver=$(curl -fsSL -m 30 https://api.github.com/repos/home-assistant/operating-system/releases/latest | jq -r '.tag_name // empty') ||
      fail "Could not ask GitHub for the newest Home Assistant OS version. Try again, or name it: RECIPE_VERSION=17.0 hs recipe homeassistant"
  fi
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "$(t "'%s' is not a Home Assistant OS version number." "$ver")"
  note "$(t 'Home Assistant OS %s' "$ver")"
  # a long step prints its progress: the size so far, every few seconds
  track='out=$1; shift; "$@" & p=$!; while kill -0 $p 2>/dev/null; do [ -f "$out" ] && echo "$(du -m "$out" | cut -f1) MB so far"; sleep 5; done; wait $p'
  spin "Downloading the image" bash -c "$track" _ "$work/haos.qcow2.xz" \
    curl -fsSL -m 1800 -o "$work/haos.qcow2.xz" "https://github.com/home-assistant/operating-system/releases/download/$ver/haos_ova-$ver.qcow2.xz"
  spin "Unpacking it" bash -c "$track" _ "$work/haos.qcow2" xz -dkf "$work/haos.qcow2.xz"
  cat > "$work/metadata.yaml" <<YAML
architecture: x86_64
creation_date: $(date +%s)
properties:
  description: Home Assistant OS $ver
  os: Home Assistant OS
  release: "$ver"
YAML
  tar -C "$work" -czf "$work/metadata.tar.gz" metadata.yaml
  incus image delete hs-haos >/dev/null 2>&1 || true
  spin "Importing it into Incus" incus image import "$work/metadata.tar.gz" "$work/haos.qcow2" --alias hs-haos

  step "Virtual machine"
  create=(--vm -c boot.autostart=true -c security.secureboot=false -c "limits.cpu=$CPU" -c "limits.memory=${RAM}MiB")
  [ "$VLAN" = default ] || create+=(--profile "$VLAN")
  spin "$(t "Creating '%s'" "$ct")" incus init hs-haos "$ct" "${create[@]}"
  incus config device override "$ct" root "size=${DISK}GiB" >/dev/null
  bash "$scripts/mac.sh" "$ct" >/dev/null
  if [ "${USB:-none}" != none ]; then
    incus config device add "$ct" usb-stick usb "vendorid=${USB%:*}" "productid=${USB#*:}" >/dev/null
    ok "$(t 'USB device %s is passed into the VM' "$USB")"
  fi
  incus image delete hs-haos >/dev/null 2>&1 || true   # the machine has its own copy
  spin "$(t "Starting '%s'" "$ct")" incus start "$ct"
else
  step "Virtual machine"
  ok "$(t "'%s' exists already, keeping it" "$ct")"
  [ "$(incus query "/1.0/instances/$ct" | jq -r .status)" = Running ] || spin "$(t "Starting '%s'" "$ct")" incus start "$ct"
fi

# ── Address ──
step "Address"
spin "Waiting for its address" bash -c "$wait_address" _ "$ct" "" 60 ||
  fail "$(t "'%s' got no address. Check the network (hs ct list), then run the recipe again." "$ct")"
ip=$(address "$ct")
if $unifi; then
  fixed_address "$ct" 20 29
else
  warn "$(t "UniFi is not connected (hs net setup), so the address %s is not fixed. Reserve it in your router by hand." "$ip")"
fi

# ── Wait for the web page ──
if [ -n "$ip" ]; then
  step "Home Assistant"
  waited='for i in $(seq 1 "$2"); do
    [ "$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://$1:8123/" 2>/dev/null)" != 000 ] && exit 0
    [ $((i % 10)) -ne 0 ] || echo "still starting, $((i * 3 / 60)) min"
    sleep 3
  done
  exit 1'
  if spin "Waiting for the web page (the first start downloads Home Assistant: 10 to 20 minutes)" bash -c "$waited" _ "$ip" 400; then
    ok "$(t 'Home Assistant answers at http://%s:8123' "$ip")"
  else
    warn "It does not answer yet. The first start can take longer: try the address in a few minutes. Console: incus console homeassistant --type=vga"
  fi
fi

if [ -n "$ip" ]; then addr="http://$ip:8123"; else addr=$(_tr "http://homeassistant.local:8123 (or the address from your router)"); fi
declare_service homeassistant "Home Assistant" home-assistant private-ok Apps "Smart home" 8123
box <<DONE
$(t 'Done. Open in the browser:   %s' "$addr")
$(say "  1. The first visit creates the owner account: name, password, home location.")
$(say "  2. Home Assistant finds many devices on its own (Settings -> Devices & services).")
$(say "     The VM is on the same network as your devices, so discovery works.")
$(say "  3. Updates run inside Home Assistant (Settings -> System -> Updates).")
$(docs_hint containers-and-apps)
DONE
