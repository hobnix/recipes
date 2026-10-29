#!/usr/bin/env bash
# recipe: Stalwart: your own mail server (SMTP, IMAP, JMAP, CalDAV/CardDAV) with a web admin page
# recipe.de: Stalwart: ein eigener Mailserver (SMTP, IMAP, JMAP, CalDAV/CardDAV) mit Web-Verwaltung
# kind: personal
# needs: tailscale
# uses: -
set -euo pipefail

# What it does: creates the container "stalwart", installs the latest Stalwart
# release (github.com/stalwartlabs/stalwart) in /opt/stalwart with its data in
# /opt/stalwart_data and a systemd service. A fresh Stalwart starts in
# "bootstrap mode": it prints a temporary admin password to the journal and the
# setup (hostname, domains, DNS records, TLS) is finished in the web page.
# Receiving mail from the internet needs port 25 forwarded by the router and
# correct DNS (MX, SPF, DKIM, DMARC, reverse DNS): that is not done here, and
# many providers block port 25. The admin page never gets a Zoraxy rule.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-stalwart}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (2048 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  download the latest Stalwart release from GitHub into /opt/stalwart (data in /opt/stalwart_data) and start it as the service stalwart"
  say "  with Tailscale = yes (asked, default no): add /dev/net/tun if the container lacks it, install Tailscale inside and sign it in (you open a link)"
  say "  leave the first setup (admin password from the journal, domains, DNS, TLS) to the web page on port 8080"
  exit 0
fi

PORT=8080   # the admin page; Stalwart's bootstrap mode listens here
setting TAILSCALE "Install Tailscale in the container (e.g. so a VPS in front can deliver mail over the tailnet)? yes or no" no no "yes|no"
ensure_container "$ct" 2048
fixed_address "$ct"
wait_internet "$ct"

if [ "$TAILSCALE" = yes ]; then
  ct_tailscale
  [ -z "$ts_ip" ] || ok "$(t 'Tailscale address: %s' "$ts_ip")"
fi

step "Install Stalwart"
if incus exec "$ct" -- test -x /opt/stalwart/stalwart </dev/null 2>/dev/null; then
  ok "installed already"
else
  in_ct "Installing tools" '$1 update -qq && $1 install -y -qq --no-install-recommends ca-certificates curl tar' "$apt_quick"
  in_ct "Downloading Stalwart" '
    asset="stalwart-$(uname -m)-unknown-linux-gnu.tar.gz"
    curl -fsSL -o /tmp/stalwart.tar.gz "https://github.com/stalwartlabs/stalwart/releases/latest/download/$asset"
    mkdir -p /opt/stalwart /opt/stalwart_data/etc /opt/stalwart_data/data /opt/stalwart_data/logs
    tar -xzf /tmp/stalwart.tar.gz -C /opt/stalwart
    rm -f /tmp/stalwart.tar.gz
    chmod 755 /opt/stalwart/stalwart
    test -x /opt/stalwart/stalwart'
fi

step "Service"
in_ct "Writing the service and starting it" '
  env=/opt/stalwart_data/etc/stalwart.env
  if [ ! -e "$env" ]; then
    ( umask 077; cat > "$env" <<ENV
# STALWART_HOSTNAME=mail.example.com
# STALWART_PUBLIC_URL=https://mail.example.com
# STALWART_RECOVERY_MODE=1
# STALWART_RECOVERY_ADMIN=admin:change-me
ENV
    )
  fi
  cat > /etc/systemd/system/stalwart.service <<UNIT
[Unit]
Description=Stalwart Mail Server
After=network-online.target
Wants=network-online.target
Conflicts=postfix.service sendmail.service exim4.service

[Service]
Type=simple
WorkingDirectory=/opt/stalwart_data
EnvironmentFile=-/opt/stalwart_data/etc/stalwart.env
ExecStart=/opt/stalwart/stalwart --config=/opt/stalwart_data/etc/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q stalwart
  systemctl restart stalwart'
note "Stalwart $(incus exec "$ct" -- /opt/stalwart/stalwart --version </dev/null 2>/dev/null | head -n1 || _tr "installed")"
wait_page Stalwart 'journalctl -u stalwart' --path /admin --plain --tries 60

declare_service stalwart Stalwart mdi-email-lock never-public Administration "Mail server (admin)" 8080

box <<DONE
$(t 'Done. The admin page is at   %s/admin' "$(web)")
$(say "  1. The first start is in bootstrap mode. The temporary admin password is in the journal:")
$(t "     incus exec %s -- sh -c \"journalctl -u stalwart | grep -A8 'bootstrap mode'\"" "$ct")
$(say "  2. Log in as admin and finish the setup there: hostname, domain, TLS certificate, accounts.")
$(say "  Never give the admin page a Zoraxy rule. Real mail traffic needs more (ports, DNS records): see the guide.")
$([ -z "${ts_ip:-}" ] || t "  Tailscale address of this container: %s" "$ts_ip")
$(docs_hint containers-and-apps)
DONE
