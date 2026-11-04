#!/usr/bin/env bash
# recipe: Claude VM, a small Linux desktop in a virtual machine with Claude Desktop, your repos on a fast share and RustDesk to get in
# recipe.de: Claude-VM, ein kleiner Linux-Desktop in einer virtuellen Maschine mit Claude Desktop, deinen Repos auf einer schnellen Freigabe und RustDesk zum Hineinschauen
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the virtual machine "claude-vm" (Debian, XFCE desktop, auto login), installs Claude Desktop from
# Anthropic's apt repository (key fingerprint checked) and RustDesk (unattended access, one random password), and passes a
# fast share (default "repos", /fast/shares/repos) into the VM at /srv/repos, linked as ~/repos.
#   user      "dev" in the VM, with the uid:gid that owns the share, so files stay editable from Windows (adminuser:users)
#   repos     a virtiofs disk device of the share; it is a ZFS dataset on the SSD pool, snapshots are switched on when the recipe makes it
#   desktop   XFCE on lightdm with auto login of "dev" (RustDesk needs a running desktop session)
#   login     one random password for "dev" (sudo) and RustDesk, in /var/lib/hs/<name>-admin (root only, vault-aware)
# Claude Desktop runs Code and Chat. Cowork needs nested virtualization (KVM) and is not set up. Updates: sudo apt upgrade in the VM.
# No Zoraxy rule, no tile: RustDesk is an admin door (reach it at home or through Tailscale).
# Not run on the real server yet. Most likely to need a second look: the virtiofs mount of the share (the host needs
# virtiofsd, part of Incus) and RustDesk's package names for a Debian release newer than the one this was written for.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1 (the files are written, no package download).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-claude-vm}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "$scripts/lib/sharepath.sh"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the virtual machine '%s' (Debian, 4096 MB RAM, 2 CPUs, 40 GB disk, asks) unless it exists, with a fixed address (.40-.49) if UniFi is connected (hs net setup)" "$ct")"
  say "  make the fast share for the repos (default: repos) unless it exists, and pass it into the VM at /srv/repos"
  say "  install the XFCE desktop with auto login of the user dev"
  say "  install Claude Desktop from Anthropic's apt repository"
  say "  install RustDesk and set a random password for unattended access"
  exit 0
fi

# ── Preferences (first setup only; the share name is asked once more per VM) ──
if ! $existed; then
  setting CPU "Number of CPUs" 2 2 "$a_number"
  setting DISK "Disk size in GB (20 or more)" 40 40 "[2-9][0-9]|[1-9][0-9]{2,}"
fi
setting SHARE "Name of the fast share with the repos (made when it does not exist)" repos repos "$a_name"

ensure_container "$ct" 4096 --vm --cpu "${CPU:-2}" --disk "${DISK:-40}"
fixed_address "$ct" 40 49
wait_internet "$ct"

# ── The repos share ──
step "Repos share"
if ! share_dir "$SHARE" >/dev/null; then
  if share_name_taken "$SHARE"; then
    fail "$(t "The name '%s' is taken by something that is not a share folder. Choose another: hs recipe %s --ask" "$SHARE" "$ct")"
  fi
  spin "$(t "Making the fast share '%s'" "$SHARE")" bash "$scripts/create-share.sh" "$SHARE" --fast
  bash "$scripts/snapshots-auto.sh" "$SHARE" on >/dev/null 2>&1 || warn "$(t "Nightly snapshots of '%s' could not be switched on: hs share <share> auto on" "$SHARE")"
fi
[ "$(share_tier "$SHARE")" = fast ] ||
  fail "$(t "The share '%s' is on the disks, not on the SSD pool. Repos need the fast one: choose another name (hs recipe %s --ask)." "$SHARE" "$ct")"
dir=$(share_dir "$SHARE")
owner=$(stat -c '%u:%g' "$dir")
uid=${owner%:*}; gid=${owner#*:}
[ "$uid" != 0 ] || fail "$(t "The share folder %s belongs to root. Run:  sudo chown adminuser:users %s" "$dir" "$dir")"
ok "$(t "%s, owner %s" "$dir" "$owner")"

if incus config device get "$ct" repos type >/dev/null 2>&1; then
  ok "$(t "'%s' has the share already" "$ct")"
else
  incus config device add "$ct" repos disk "source=$dir" path=/srv/repos >/dev/null
  # the VM mounts it when it starts
  spin "$(t "Restarting '%s' to mount the share" "$ct")" incus restart "$ct"
  spin "Waiting for its address" bash -c "$wait_address" _ "$ct" "" 60 ||
    fail "$(t "'%s' got no address. Check the network (hs ct list), then run the recipe again." "$ct")"
  ip=$(address "$ct")
  ok "$(t "The share is passed into '%s' (virtiofs)" "$ct")"
fi

# ── Login ──
step "Login"
# one password for the user dev (sudo) and RustDesk; kept when it exists
if [ "$(secret_state "$state/$ct-admin")" = locked ]; then
  secret_locked_exit
elif [ -s "$state/$ct-admin" ]; then
  ok "$(t 'Kept as it is (password in %s/%s-admin)' "$state" "$ct")"
else
  secret_prepare "$ct-admin" "$state" || exit 1
  pw=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 || true)
  ( umask 077; printf 'user: dev\npassword: %s\n' "$pw" > "$state/$ct-admin" )
  ok "$(t 'Password written to %s/%s-admin' "$state" "$ct")"
fi
pw=$(sed -n 's/^password: //p' "$state/$ct-admin" | head -n1 || true)
[ -n "$pw" ] || fail "$(t 'No password in %s/%s-admin' "$state" "$ct")"

rdid=""
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no packages, nothing installed"
else
  # the password goes into the VM as a root-only file, never through a command line
  work=$(mktemp -d /var/tmp/hs-claude-vm.XXXXXX)
  trap 'rm -rf "$work"' EXIT
  ( umask 077; printf 'dev:%s\n' "$pw" > "$work/login"; printf '%s\n' "$pw" > "$work/rd" )
  incus file push --mode=0600 "$work/login" "$ct/root/.hs-login" >/dev/null
  incus file push --mode=0600 "$work/rd" "$ct/root/.hs-rd" >/dev/null

  in_ct "Installing the desktop (XFCE)" '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg sudo git openssh-client \
      xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils dbus-x11 \
      xfce4 xfce4-terminal thunar lightdm lightdm-gtk-greeter polkitd pkexec \
      pulseaudio firefox-esr fonts-dejavu-core gnome-keyring libsecret-1-0 xdg-utils'

  in_ct "Making the user dev" '
    uid=$1; gid=$2
    getent group "$gid" >/dev/null || groupadd -g "$gid" repos
    old=$(getent passwd "$uid" | cut -d: -f1 || true)
    if [ -n "$old" ] && [ "$old" != dev ]; then
      usermod -l dev -d /home/dev -m "$old"
    elif [ -z "$old" ]; then
      id dev >/dev/null 2>&1 || useradd -m -s /bin/bash -u "$uid" -g "$gid" dev
    fi
    usermod -g "$gid" -aG sudo,audio,video dev
    chpasswd < /root/.hs-login
    ln -sfn /srv/repos /home/dev/repos
    chown -h dev: /home/dev/repos' "$uid" "$gid"

  in_ct "Setting up the login screen (auto login of dev)" '
    install -d /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-hs-claude-vm.conf <<LIGHTDM
[Seat:*]
autologin-user=dev
autologin-user-timeout=0
user-session=xfce
LIGHTDM
    systemctl set-default graphical.target >/dev/null
    systemctl enable lightdm >/dev/null 2>&1 || true'

  in_ct "Installing Claude Desktop (from Anthropic)" '
    key=/usr/share/keyrings/claude-desktop-archive-keyring.asc
    curl -fsSLo "$key" https://downloads.claude.ai/claude-desktop/key.asc
    fp=$(gpg --show-keys --with-colons "$key" | awk -F: "/^fpr:/ {print \$10; exit}")
    if [ "$fp" != 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ]; then
      echo "The signing key of Anthropic has the fingerprint $fp, not the one in the documentation. Nothing installed."
      exit 1
    fi
    echo "deb [arch=amd64,arm64 signed-by=$key] https://downloads.claude.ai/claude-desktop/apt/stable stable main" > /etc/apt/sources.list.d/claude-desktop.list
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends claude-desktop'

  ver=${RECIPE_VERSION:-}
  if [ -z "$ver" ]; then
    ver=$(curl -fsSL -m 30 https://api.github.com/repos/rustdesk/rustdesk/releases/latest | jq -r '.tag_name // empty') ||
      fail "Could not ask GitHub for the newest RustDesk version. Try again, or name it: RECIPE_VERSION=1.4.0 hs recipe claude-vm"
  fi
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "$(t "'%s' is not a RustDesk version number." "$ver")"
  note "$(t 'RustDesk %s' "$ver")"
  in_ct "Installing RustDesk" '
    if [ "$(dpkg-query -W -f="\${Version}" rustdesk 2>/dev/null || true)" != "$1" ]; then
      curl -fsSL -m 600 -o /tmp/rustdesk.deb "https://github.com/rustdesk/rustdesk/releases/download/$1/rustdesk-$1-x86_64.deb"
      apt-get install -y -qq /tmp/rustdesk.deb
      rm -f /tmp/rustdesk.deb
    fi
    # the tray icon in the desktop of dev; the service (root) is what accepts the connection
    cat > /etc/xdg/autostart/hs-rustdesk.desktop <<DESKTOP
[Desktop Entry]
Type=Application
Name=RustDesk
Exec=rustdesk --tray
DESKTOP
    systemctl enable --now rustdesk >/dev/null 2>&1
    sleep 4
    rustdesk --password "$(cat /root/.hs-rd)" >/dev/null 2>&1
    systemctl restart rustdesk' "$ver"

  in_ct "Starting the desktop" 'systemctl restart lightdm; rm -f /root/.hs-login /root/.hs-rd'

  rdid=$(incus exec "$ct" -- bash -c 'for _ in $(seq 1 15); do i=$(rustdesk --get-id 2>/dev/null | grep -Eo "[0-9]{6,}" | tail -n1); [ -n "$i" ] && { echo "$i"; exit 0; }; sleep 2; done' </dev/null || true)
  if [ -n "$rdid" ]; then
    ok "$(t 'RustDesk ID: %s' "$rdid")"
  else
    warn "$(t 'RustDesk has no ID yet. Ask for it in a minute:  incus exec %s -- rustdesk --get-id' "$ct")"
  fi
  incus exec "$ct" -- mountpoint -q /srv/repos </dev/null ||
    warn "$(t 'The share is not mounted in the VM. Look at: incus config device show %s ; incus exec %s -- journalctl -u incus-agent -n 40' "$ct" "$ct")"
fi

recipe_facts
box <<DONE
$(say "The VM is running. Get in with RustDesk (rustdesk.com, on your PC or phone):")
$(t '  1. Connect to the ID  %s  (the address is %s).' "${rdid:-<ID>}" "${ip:-?}")
$(t '     User dev, password in %s/%s-admin (also the sudo password).' "$state" "$ct")
$(say "  2. Open Claude on the desktop and sign in with your Anthropic account (it opens Firefox).")
$(t '  3. Your repos are in ~/repos (the share %s, also reachable from your PC).' "$SHARE")
$(say "Updates: sudo apt update && sudo apt upgrade in the VM. Claude Desktop does not update itself on Linux.")
$(say "RustDesk is an admin door: never a Zoraxy rule.")
$(docs_hint claude-vm)
DONE
