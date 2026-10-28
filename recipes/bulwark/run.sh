#!/usr/bin/env bash
# recipe: Bulwark Mail: a webmail page (mail, calendar, contacts) for your Stalwart mail server
# recipe.de: Bulwark Mail: eine Webmail-Seite (Mail, Kalender, Kontakte) für deinen Stalwart-Mailserver
# kind: generic
# needs: docker
# uses: -
set -euo pipefail

# What it does: creates the container "bulwark" with Docker and runs the official
# image ghcr.io/bulwarkmail/webmail (a JMAP client: it holds no mail, Stalwart does).
# The address of Stalwart (JMAP_SERVER_URL) is asked; with the recipe "stalwart"
# already installed its address is the default. The admin password (ADMIN_PASSWORD,
# /opt/bulwark/.env in the container) and SESSION_SECRET are made here; without them the admin page is off or fails.
# Users log in with their Stalwart account. Unlike Stalwart's admin page the
# webmail page may get a Zoraxy rule if you want to read mail from outside.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-bulwark}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (1024 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Docker inside and run ghcr.io/bulwarkmail/webmail with docker compose in /opt/bulwark (asks for the port, default 80)"
  say "  connect it to your Stalwart server (asked, default: the container 'stalwart' if there is one)"
  say "  make an admin password for the admin page (/admin), kept in /opt/bulwark/.env"
  exit 0
fi

port_setting "Bulwark Mail" 3000

# the JMAP server: the stalwart container when there is one
default_jmap=
if stalwart_ip=$(address stalwart 2>/dev/null) && [ -n "$stalwart_ip" ]; then default_jmap="http://$stalwart_ip:8080"; fi
setting JMAP_URL "Address of your Stalwart server" "${default_jmap:-https://mail.example.com}" "${default_jmap:-https://mail.example.com}" 'https?://[^ ]+'

ensure_container "$ct" 1024 --docker
fixed_address "$ct"
wait_internet "$ct"
install_docker

step "Bulwark Mail"
in_ct "Writing the settings (port, mail server)" '
  mkdir -p /opt/bulwark/data && cd /opt/bulwark
  # the image runs as uid 1001 (nextjs), group 65533: it must be able to write its settings
  chown 1001:65533 data
  # the admin password is made once and kept: it must not change at a re-run
  # (SESSION_SECRET signs the admin login: without it the login ends in an Internal Server Error)
  touch .env; chmod 600 .env
  grep -q "^ADMIN_PASSWORD=" .env || printf "ADMIN_PASSWORD=%s
" "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24 || true)" >> .env
  grep -q "^SESSION_SECRET=" .env || printf "SESSION_SECRET=%s
" "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48 || true)" >> .env
  cat > docker-compose.yml <<YML
services:
  bulwark:
    image: ghcr.io/bulwarkmail/webmail:latest
    container_name: bulwark
    restart: unless-stopped
    ports:
      - "$1:3000"
    env_file: .env
    environment:
      - JMAP_SERVER_URL=$2
    volumes:
      - ./data:/app/data
YML
  docker compose config -q' "$PORT" "$JMAP_URL"
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Bulwark not started"
else
  in_ct "Downloading Bulwark Mail" 'cd /opt/bulwark && docker compose pull -q'
  in_ct "Starting Bulwark Mail" 'cd /opt/bulwark && docker compose up -d --remove-orphans'
  wait_page Bulwark 'docker compose -f /opt/bulwark/docker-compose.yml logs --tail 50' --plain --tries 60
fi

recipe_facts web
declare_service bulwark Bulwark mdi-email-outline private-ok Apps "Webmail"
box <<DONE
$(t "Mail server: %s" "$JMAP_URL")
$(say "Log in with an account of your Stalwart server. The admin page is /admin, its password:")
$(t "  incus exec %s -- cat /opt/bulwark/.env" "$ct")
$(docs_hint containers-and-apps)
DONE
