#!/usr/bin/env bash
# recipe: Claude VM, a Linux machine for Claude Code with Remote Desktop, SSH, dev tools and Docker, your repos on a fast share
# recipe.de: Claude-VM, eine Linux-Maschine für Claude Code mit Remote Desktop, SSH, Entwickler-Werkzeugen und Docker, deine Repos auf einer schnellen Freigabe
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the virtual machine "claude-vm" (Debian, 8192 MB RAM, 4 CPUs, no GPU), installs the Claude Code CLI and
# Claude Desktop from Anthropic's apt repositories (key fingerprint checked), SSH, developer tools, Docker and an XFCE desktop
# that you reach with Remote Desktop (xrdp, mstsc on Windows). A fast share (default "repos", /fast/shares/repos) is passed into
# the VM at /srv/repos, linked as ~/repos.
#   user      "dev" in the VM, with the uid:gid that owns the share, so files stay editable from Windows (adminuser:users)
#   repos     a virtiofs disk device of the share; it is a ZFS dataset on the SSD pool, snapshots are switched on when the recipe makes it
#   desktop   XFCE, started by xrdp for each Remote Desktop login (no display manager, no auto login, compositing off)
#   login     one random password for "dev" (Remote Desktop, sudo, SSH), in /var/lib/hs/<name>-admin (root only, vault-aware)
#   ssh       openssh-server; your public key (asked) goes into ~dev/.ssh/authorized_keys
#   claude    the unit claude-remote@<repo> runs "claude remote-control" in /srv/repos/<repo>; the recipe enables none (sign in first)
# Cowork needs nested virtualization (KVM) and is not promised. Updates: sudo apt upgrade in the VM.
# No Zoraxy rule, no tile: Remote Desktop (3389) and SSH are admin doors (reach them at home or through Tailscale).
# Not run on the real server yet. Most likely to need a second look: the virtiofs mount of the share (the host needs
# virtiofsd, part of Incus), xrdp with XFCE on the Debian release of the VM, and whether claude-remote runs without a terminal.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1 (the files are written, no package download).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-claude-vm}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "$scripts/lib/sharepath.sh"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the virtual machine '%s' (Debian, 8192 MB RAM, 4 CPUs, 40 GB disk, asks) unless it exists, with a fixed address (.40-.49) if UniFi is connected (hs net setup)" "$ct")"
  say "  make the fast share for the repos (default: repos) unless it exists, and pass it into the VM at /srv/repos"
  say "  install the XFCE desktop and xrdp (Remote Desktop, login as the user dev)"
  say "  install SSH and, if you give one, your public key"
  say "  install Claude Code from Anthropic's apt repository, and the unit claude-remote@<repo> (none enabled)"
  say "  install developer tools (git, gh, ripgrep, Node.js, Python ...) and Docker"
  say "  install Claude Desktop from Anthropic's apt repository"
  exit 0
fi

# ── Preferences (first setup only; the share name is asked once more per VM; the SSH key is asked on a new VM, and on an existing one only with --ask) ──
if ! $existed; then
  setting CPU "Number of CPUs" 4 2 "$a_number"
  setting DISK "Disk size in GB (20 or more)" 40 40 "[2-9][0-9]|[1-9][0-9]{2,}"
fi
setting SHARE "Name of the fast share with the repos (made when it does not exist)" repos repos "$a_name"
setting SSHKEY "Your public SSH key (one line, - for none)" - - "-|(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+=*( [^ ].*)?"

ensure_container "$ct" 8192 --vm --cpu "${CPU:-4}" --disk "${DISK:-40}"
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
# one password for the user dev (Remote Desktop, sudo, SSH); kept when it exists
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

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no packages, nothing installed"
else
  # the password goes into the VM as a root-only file, never through a command line
  work=$(mktemp -d /var/tmp/hs-claude-vm.XXXXXX)
  trap 'rm -rf "$work"' EXIT
  ( umask 077; printf 'dev:%s\n' "$pw" > "$work/login" )
  incus file push --mode=0600 "$work/login" "$ct/root/.hs-login" >/dev/null

  in_ct "Installing the desktop (XFCE) and Remote Desktop (xrdp)" '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg sudo git openssh-client openssh-server \
      xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils dbus-x11 xauth \
      xfce4 xfce4-terminal thunar polkitd pkexec xrdp xorgxrdp \
      pulseaudio firefox-esr fonts-dejavu-core gnome-keyring libpam-gnome-keyring libsecret-1-0 xdg-utils'

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
    rm -f /root/.hs-login /root/.hs-rd
    ln -sfn /srv/repos /home/dev/repos
    chown -h dev: /home/dev/repos' "$uid" "$gid"

  # a VM of version 1 had RustDesk and a desktop that logged dev in by itself
  in_ct "Removing what the first version set up" '
    if dpkg -s rustdesk >/dev/null 2>&1; then
      systemctl disable --now rustdesk >/dev/null 2>&1 || true
      apt-get purge -y -qq rustdesk
    fi
    rm -f /etc/xdg/autostart/hs-rustdesk.desktop /etc/lightdm/lightdm.conf.d/50-hs-claude-vm.conf
    systemctl disable --now lightdm >/dev/null 2>&1 || true
    systemctl set-default multi-user.target >/dev/null'

  in_ct "Setting up Remote Desktop for dev" '
    printf "xfce4-session\n" > /home/dev/.xsession
    chown dev: /home/dev/.xsession
    # a remote session has no GPU: no compositing (smoother and no flicker)
    install -d /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
    cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<XFWM
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWM
    # no "authentication required to create a color managed device" window in the remote session
    install -d /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/45-hs-xrdp-colord.rules <<POLKIT
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
    return polkit.Result.YES;
  }
});
POLKIT
    # xrdp reads its TLS key through the group ssl-cert; a running xrdp needs a restart to see the group
    if ! id -nG xrdp | tr " " "\n" | grep -qx ssl-cert; then
      usermod -aG ssl-cert xrdp
      systemctl restart xrdp >/dev/null 2>&1 || true
    fi
    systemctl enable --now xrdp >/dev/null 2>&1'

  in_ct "Setting up SSH" '
    systemctl enable --now ssh >/dev/null 2>&1
    key=$1
    if [ "$key" != - ]; then
      install -d -m 0700 -o dev -g "$(id -g dev)" /home/dev/.ssh
      touch /home/dev/.ssh/authorized_keys
      grep -qxF "$key" /home/dev/.ssh/authorized_keys || printf "%s\n" "$key" >> /home/dev/.ssh/authorized_keys
      chmod 600 /home/dev/.ssh/authorized_keys
      chown dev: /home/dev/.ssh/authorized_keys
    fi' "$SSHKEY"

  in_ct "Installing Claude Code (from Anthropic)" '
    install -d -m 0755 /etc/apt/keyrings
    key=/etc/apt/keyrings/claude-code.asc
    curl -fsSLo "$key" https://downloads.claude.ai/keys/claude-code.asc
    fp=$(gpg --show-keys --with-colons "$key" | awk -F: "/^fpr:/ {print \$10; exit}")
    if [ "$fp" != 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ]; then
      echo "The signing key of Anthropic has the fingerprint $fp, not the one in the documentation. Nothing installed."
      exit 1
    fi
    echo "deb [signed-by=$key] https://downloads.claude.ai/claude-code/apt/stable stable main" > /etc/apt/sources.list.d/claude-code.list
    apt-get update -qq
    apt-get install -y -qq claude-code
    command -v claude >/dev/null'

  # the template unit: one instance per repo in /srv/repos; none is enabled here (it needs a sign-in and a cloned repo first)
  in_ct "Installing the Remote Control unit" '
    bin=$(command -v claude)
    cat > /etc/systemd/system/claude-remote@.service <<UNIT
[Unit]
Description=Claude Code Remote Control in /srv/repos/%i
After=network-online.target
Wants=network-online.target

[Service]
User=dev
WorkingDirectory=/srv/repos/%i
ExecStart=$bin remote-control --spawn worktree
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload'

  in_ct "Installing developer tools" '
    apt-get install -y -qq --no-install-recommends git gh ripgrep fd-find jq build-essential python3 python3-venv python3-pip pipx \
      nodejs npm shellcheck shfmt direnv tmux unzip zip wget less man-db'

  install_docker
  in_ct "Letting dev use Docker" 'usermod -aG docker dev'

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
    apt-get install -y -qq --no-install-recommends claude-desktop
    # for Cowork (nested virtualization is not verified)
    if getent group kvm >/dev/null; then usermod -aG kvm dev; fi'

  incus exec "$ct" -- mountpoint -q /srv/repos </dev/null ||
    warn "$(t 'The share is not mounted in the VM. Look at: incus config device show %s ; incus exec %s -- journalctl -u incus-agent -n 40' "$ct" "$ct")"
fi

recipe_facts
box <<DONE
$(say "The VM is running. Three ways in:")
$(t '  1. Remote Desktop (mstsc on Windows): connect to %s as dev.' "${ip:-?}")
$(t '  2. SSH: ssh dev@%s' "${ip:-?}")
$(say "  3. Remote Control: after the sign-in, from claude.ai/code or the phone app (see the guide).")
$(say "First steps in the VM: claude (then /login), gh auth login, git config --global user.name and user.email.")
$(t 'The password of dev (also for sudo) is in %s/%s-admin.' "$state" "$ct")
$(t '  Your repos are in ~/repos (the share %s, also reachable from your PC).' "$SHARE")
$(say "Updates: sudo apt update && sudo apt upgrade in the VM. Claude Desktop does not update itself on Linux.")
$(say "Port 3389 and SSH are admin doors: never a Zoraxy rule.")
$(docs_hint claude-vm)
DONE
