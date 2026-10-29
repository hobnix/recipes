#!/usr/bin/env bash
# recipe: Domain: the domain controller for users and groups, and this server joined to it
# recipe.de: Domäne: der Domänencontroller für Benutzer und Gruppen, und dieser Server als Mitglied
# kind: personal
# needs: -
# input: terminal
# uses: -
set -euo pipefail

# What it does, in two parts. Running it again continues where it stopped.
#   1. the controller   a virtual machine "dc1" (a container can't do it) with
#                       Samba as Active Directory domain controller. It needs a
#                       fixed address before the domain is created.
#   2. this server      joins the domain as file server (adDomain in
#                       machine.toml, a rebuild, `net ads join`), so share
#                       logins and groups come from the domain.
# With --join <ip of the first controller> (a second server of an existing domain)
# part 1 is different: the virtual machine (named dc2 then) does not create a domain, it
# joins the existing one as a second controller and copies it (guide "Benutzer und
# Freigaben", section 4). Users and passwords are then on both servers.
# Between the two, the router has to learn where the domain lives (one DNS
# entry in UniFi); the recipe says exactly what to enter and waits for it.
# Passwords are typed on the terminal, straight into Samba; the recipe never
# sees them.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
join_dc=${RECIPE_JOIN_DC:-}; dry=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true ;;
    --join) join_dc=${2:-}; [ $# -gt 1 ] && shift ;;
    *) echo "usage: hs recipe domain [--join <address of the first domain controller>] [--dry-run]" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$join_dc" ] && ! [[ "$join_dc" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "--join needs the IP address of the first domain controller, for example 10.10.95.40" >&2; exit 2
fi
ct=${RECIPE_NAME:-$([ -n "$join_dc" ] && echo dc2 || echo dc1)}
machine=${HS_MACHINE_FILE:-/etc/nixos/machine.toml}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if $dry && [ -n "$join_dc" ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the virtual machine '%s' (2 GB RAM, 2 cores, 20 GB) unless it exists, with a fixed address (.40 to .49)" "$ct")"
  say "  install Samba inside and join the existing domain as a second domain controller (asks for the Administrator password)"
  printf '%s\n' "$(t '  copy the domain from %s and check that the copying works' "$join_dc")"
  say "  tell you the second DNS entry the router needs"
  printf '%s\n' "$(t '  add adDomain to %s, rebuild, join this server to the domain (asks for the Administrator password)' "$machine")"
  exit 0
fi
if $dry; then
  say "Would:"
  printf '%s\n' "$(t "  create the virtual machine '%s' (2 GB RAM, 2 cores, 20 GB) unless it exists, with a fixed address (.40 to .49)" "$ct")"
  say "  install Samba inside and create the domain (asks for its name and the Administrator password)"
  say "  tell you the DNS entry the router needs, and continue once it works"
  printf '%s\n' "$(t '  add adDomain to %s, rebuild, join this server to the domain (asks for the Administrator password)' "$machine")"
  exit 0
fi

sam=/var/lib/samba/private/sam.ldb
provisioned() { incus exec "$ct" -- test -e "$sam" </dev/null 2>/dev/null; }

ensure_container "$ct" 2048 --vm --cpu 2 --disk 20
# a VM answers commands only once its agent runs
spin "Waiting for the virtual machine to accept commands" \
  bash -c 'for _ in $(seq 1 60); do incus exec "$1" -- true </dev/null 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$ct" ||
  fail "$(t "'%s' does not answer. Look at it in: hs ct list" "$ct")"

# ── part 1: the controller ──
if provisioned; then
  step "Domain"
  realm=$(incus exec "$ct" -- sh -c "samba-tool domain info 127.0.0.1 2>/dev/null | sed -n 's/^Domain *: *//p'" </dev/null | tr 'a-z' 'A-Z')
  short=$(incus exec "$ct" -- sh -c "samba-tool domain info 127.0.0.1 2>/dev/null | sed -n 's/^Netbios domain *: *//p'" </dev/null)
  [ -n "$realm" ] && [ -n "$short" ] || fail "$(t "'%s' has a domain, but it does not answer. Look at: incus exec %s -- systemctl status samba-ad-dc" "$ct" "$ct")"
  ok "$(t 'The domain %s (short name %s) exists already, keeping it' "$realm" "$short")"
elif [ -n "$join_dc" ]; then
  # a second controller of an existing domain: its address is written into the domain too
  fixed_address "$ct" 40 49
  if [ ! -r "$state/unifi" ]; then
    confirm "$(t "Is %s reserved for '%s' in UniFi (Client Devices -> Fixed IP Address)? Without that the domain breaks when the address changes." "$ip" "$ct")" ||
      fail "Reserve the address first (or run: hs net setup), then start the recipe again."
  fi
  wait_internet "$ct"

  step "The existing domain"
  note "$(t 'The first controller is %s. It must be running, and this server must reach it (DNS, Kerberos, LDAP, SMB).' "$join_dc")"
  realm=${RECIPE_REALM:-$(ask "Full name of the existing domain" "ad.home.lan")}
  realm=$(tr 'a-z' 'A-Z' <<<"$realm")
  [[ "$realm" =~ ^[A-Z0-9-]+(\.[A-Z0-9-]+)+$ ]] || fail "$(t "'%s' is not a usable name (letters, digits, at least one dot)." "$realm")"
  lower=$(tr 'A-Z' 'a-z' <<<"$realm")
  router=$(incus exec "$ct" -- sh -c "ip route show default | awk '{ print \$3; exit }'" </dev/null)

  step "Install Samba"
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing Samba (about 150 MB)" '$1 install -y -qq samba-ad-dc krb5-user winbind smbclient ldb-tools dnsutils chrony attr acl' "$apt_quick"
  in_ct "Stopping the services the package started" '
    systemctl disable -q --now smbd nmbd winbind samba-ad-dc 2>/dev/null || true
    systemctl mask -q smbd nmbd winbind'

  step "$(t 'Join the domain %s as a controller' "$realm")"
  in_ct "Preparing name and DNS of the controller" '
    hostnamectl set-hostname "$1"
    sed -i "/^127\.0\.1\.1/d" /etc/hosts
    grep -q " $1\.$3 " /etc/hosts || echo "$2 $1.$3 $1" >> /etc/hosts
    systemctl disable -q --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf "search %s\nnameserver %s\n" "$3" "$4" > /etc/resolv.conf' "$ct" "$ip" "$lower" "$join_dc"
  spin "Checking that the first controller answers" incus exec "$ct" -- sh -c '
    for _ in $(seq 1 15); do host -t SRV "_ldap._tcp.$0" "$1" >/dev/null 2>&1 && exit 0; sleep 2; done
    exit 1' "$lower" "$join_dc" ||
    fail "$(t 'No domain controller for %s answers at %s. Is it running? Are the ports open between the two networks (53, 88, 135, 389, 445, 3268)?' "$lower" "$join_dc")"
  note "The Administrator password of the existing domain is asked for now. It is typed straight into Samba."
  incus exec "$ct" -t -- sh -c '
    [ ! -e /etc/samba/smb.conf ] || mv /etc/samba/smb.conf /etc/samba/smb.conf.orig
    find /var/lib/samba /var/cache/samba /run/samba -type f \( -name "*.tdb" -o -name "*.ldb" \) -delete
    samba-tool domain join "$1" DC -U Administrator --dns-backend=SAMBA_INTERNAL --option="dns forwarder = $2"' _ "$lower" "$router" ||
    fail "Joining as a controller failed. Is the Administrator password right? Run the recipe again to retry."
  in_ct "Starting the controller" '
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    systemctl unmask -q samba-ad-dc
    systemctl enable -q --now samba-ad-dc
    printf "search %s\nnameserver %s\nnameserver %s\n" "$1" "$2" "$3" > /etc/resolv.conf' "$lower" "$ip" "$join_dc"
  spin "Waiting for the first copy of the domain" incus exec "$ct" -- sh -c '
    for _ in $(seq 1 60); do
      o=$(samba-tool drs showrepl 2>&1) && echo "$o" | grep -q "was successful" &&
        ! echo "$o" | grep -Eq "^[[:space:]]*[1-9][0-9]* consecutive failure" && exit 0
      sleep 5
    done
    exit 1' ||
    fail "$(t 'The copying does not work. Look at: incus exec %s -- samba-tool drs showrepl' "$ct")"
  short=$(incus exec "$ct" -- sh -c "samba-tool domain info 127.0.0.1 2>/dev/null | sed -n 's/^Netbios domain *: *//p'" </dev/null)
  [ -n "$short" ] || fail "$(t "'%s' joined, but does not say the short name of the domain. Look at: incus exec %s -- samba-tool domain info 127.0.0.1" "$ct" "$ct")"
  spin "Taking a snapshot of the new controller" incus snapshot create "$ct" fresh-join || true
else
  # the controller's address is written into the domain: it must not change afterwards
  fixed_address "$ct" 40 49
  if [ ! -r "$state/unifi" ]; then
    confirm "$(t "Is %s reserved for '%s' in UniFi (Client Devices -> Fixed IP Address)? Without that the domain breaks when the address changes." "$ip" "$ct")" ||
      fail "Reserve the address first (or run: hs net setup), then start the recipe again."
  fi
  wait_internet "$ct"

  step "Name of the domain"
  note "A name that exists nowhere on the internet, ending in a name of yours, for example ad.home.lan."
  note "$(t 'The short name is what people type before their user name: %s.' 'HOME\simon')"
  realm=${RECIPE_REALM:-$(ask "Full name of the domain" "ad.home.lan")}
  realm=$(tr 'a-z' 'A-Z' <<<"$realm")
  [[ "$realm" =~ ^[A-Z0-9-]+(\.[A-Z0-9-]+)+$ ]] || fail "$(t "'%s' is not a usable name (letters, digits, at least one dot)." "$realm")"
  short=${RECIPE_DOMAIN:-$(ask "Short name (max. 15 letters)" "$(cut -d. -f2 <<<"$realm")")}
  short=$(tr 'a-z' 'A-Z' <<<"$short")
  [[ "$short" =~ ^[A-Z0-9]{1,15}$ ]] || fail "$(t "'%s' is not a usable short name (letters and digits, at most 15)." "$short")"
  lower=$(tr 'A-Z' 'a-z' <<<"$realm")
  router=$(incus exec "$ct" -- sh -c "ip route show default | awk '{ print \$3; exit }'" </dev/null)

  step "Install Samba"
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing Samba (about 150 MB)" '$1 install -y -qq samba-ad-dc krb5-user winbind smbclient ldb-tools dnsutils chrony attr acl' "$apt_quick"
  # the package starts services a domain controller must not run
  in_ct "Stopping the services the package started" '
    systemctl disable -q --now smbd nmbd winbind samba-ad-dc 2>/dev/null || true
    systemctl mask -q smbd nmbd winbind'

  step "$(t 'Create the domain %s' "$realm")"
  in_ct "Preparing name and DNS of the controller" '
    hostnamectl set-hostname "$1"
    sed -i "/^127\.0\.1\.1/d" /etc/hosts
    grep -q " $1\.$3 " /etc/hosts || echo "$2 $1.$3 $1" >> /etc/hosts
    # the controller becomes the DNS server of the domain: nothing else may sit on port 53
    systemctl disable -q --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver $4" > /etc/resolv.conf' "$ct" "$ip" "$lower" "$router"
  in_ct "Creating the domain" '
    [ ! -e /etc/samba/smb.conf ] || mv /etc/samba/smb.conf /etc/samba/smb.conf.orig
    find /var/lib/samba /var/cache/samba /run/samba -type f \( -name "*.tdb" -o -name "*.ldb" \) -delete
    samba-tool domain provision --use-rfc2307 --realm="$1" --domain="$2" \
      --server-role=dc --dns-backend=SAMBA_INTERNAL --host-ip="$3" \
      --option="dns forwarder = $4" >/dev/null 2>&1' "$realm" "$short" "$ip" "$router"
  in_ct "Starting the controller" '
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    systemctl unmask -q samba-ad-dc
    systemctl enable -q --now samba-ad-dc
    printf "search %s\nnameserver %s\n" "$1" "$2" > /etc/resolv.conf' "$lower" "$ip"
  spin "Checking that it answers" incus exec "$ct" -- sh -c '
    for _ in $(seq 1 30); do
      host -t SRV "_ldap._tcp.$0" >/dev/null 2>&1 && host -t A debian.org >/dev/null 2>&1 && exit 0
      sleep 2
    done
    exit 1' "$lower" ||
    fail "$(t 'The controller does not answer for %s. Look at: incus exec %s -- journalctl -u samba-ad-dc -n 30' "$lower" "$ct")"

  step "Password of the domain's Administrator"
  note "At least 7 characters with upper and lower case letters and digits. Typed twice, not shown."
  note "This account manages the domain; keep the password somewhere safe."
  if [ -n "${RECIPE_SKIP_PASSWORD:-}" ]; then
    note "skipped (RECIPE_SKIP_PASSWORD): the random one from the setup stays"
  else
    incus exec "$ct" -t -- samba-tool user setpassword Administrator ||
      warn "$(t 'The password was not set. Do it later: incus exec %s -t -- samba-tool user setpassword Administrator' "$ct")"
  fi
  spin "Taking a snapshot of the fresh controller" incus snapshot create "$ct" fresh-domain || true
fi
lower=$(tr 'A-Z' 'a-z' <<<"$realm")
ip=$(address "$ct")

# ── between the parts: the router must hand the domain's names to the controller ──
step "The domain in your network"
resolves() { getent hosts "$ct.$lower" 2>/dev/null | grep -q "^$ip "; }
if [ -n "$join_dc" ]; then
  box <<TEXT
$(say "The router already sends the domain to the first controller. Add a SECOND entry, so it asks this one when the first is off.")
$(say "In UniFi, where the local DNS entries are:")
$(say "  Type          Forward Domain")
$(t '  Domain Name   %s' "$lower")
$(t '  DNS Server    %s' "$ip")
TEXT
  if resolves; then ok "$(t '%s resolves to %s' "$ct.$lower" "$ip")"; else note "$(t '%s does not resolve yet; the first controller may still be copying the new name' "$ct.$lower")"; fi
else
  if ! resolves; then
    box <<TEXT
$(say "The router does not know the domain yet. In UniFi, where the local DNS entries are:")
$(say "  Type          Forward Domain")
$(t '  Domain Name   %s' "$lower")
$(t '  DNS Server    %s' "$ip")
$(say "Then run this recipe again: it continues from here and joins this server to the domain.")
$(t 'Check on a PC:   nslookup %s    (must answer %s)' "$ct.$lower" "$ip")
TEXT
    exit 0
  fi
  ok "$(t '%s resolves to %s' "$ct.$lower" "$ip")"
fi

# ── part 2: this server joins as file server ──
step "This server as file server of the domain"
if [ -n "${RECIPE_SKIP_HOST:-}" ]; then
  note "skipped (RECIPE_SKIP_HOST)"
  exit 0
fi
if [ "$(testparm -s --parameter-name=security 2>/dev/null)" = ADS ]; then
  ok "The configuration already names a domain"
else
  line="adDomain = { realm = \"$realm\", workgroup = \"$short\" }"
  machine_set adDomain "{ realm = \"$realm\", workgroup = \"$short\" }" recipe || true
  machine_has adDomain || fail "$(t 'Could not add adDomain to %s. Add this line by hand, run hs rebuild, then the recipe again:  %s' "$machine" "$line")"
  ok "$(t 'Added to %s:  %s' "$machine" "$line")"
  bash "$scripts/rebuild.sh"
fi

if wbinfo -t >/dev/null 2>&1; then
  ok "This server is a member of the domain already"
else
  note "The Administrator password of the domain is asked for now (twice: joining, then a permission)."
  net ads join -U Administrator || fail "Joining failed. Is the password right? Run the recipe again to retry."
  systemctl restart samba-winbindd samba-smbd
  spin "Waiting for the connection to the domain" bash -c 'for _ in $(seq 1 20); do wbinfo -t >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' ||
    fail "The server joined, but can't talk to the domain. Look at: journalctl -u samba-winbindd -n 30"
  # lets Domain Admins change who may use a share (from Windows too)
  net rpc rights grant "$short\\Domain Admins" SeDiskOperatorPrivilege -U Administrator >/dev/null ||
    warn "$(t "Could not let Domain Admins manage share permissions. Later: sudo net rpc rights grant '%s' SeDiskOperatorPrivilege -U Administrator" "$short\\Domain Admins")"
fi
bash "$scripts/sync-shares.sh" >/dev/null 2>&1 || true

who_user="$short\\<user>"
who_admin="$short\\Administrator"
recipe_facts
kv "Domain" "$realm"
box <<DONE
$(say "The domain is running and this server is its file server.")
$(t 'People log in to shares as   %s   with their domain password; a Windows PC joins with %s.' "$who_user" "$who_admin")
$(say "Shares that existed before are still open to everyone: close them in hs share <share> perm (Everyone: none). hs health lists them.")
$(docs_hint containers-and-apps)
DONE
if [ -n "$join_dc" ]; then
  note "$(t 'This server also holds a copy of the domain (controller %s); hs finds it by itself.' "$ct")"
fi
