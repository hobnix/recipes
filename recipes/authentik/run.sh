#!/usr/bin/env bash
# recipe: Authentik: one login for your services (AD accounts for you, local accounts for friends)
# recipe.de: Authentik: ein Login für deine Dienste (AD-Konten für dich, lokale Konten für Freunde)
# kind: generic
# needs: docker
# uses: -
set -euo pipefail

# What it does: creates the container "authentik" with Docker inside and runs
# Authentik the way its makers ship it (their docker-compose.yml: server,
# worker, PostgreSQL). Everything lives in the container (/opt/authentik):
# the database in /opt/authentik/postgres, so a backup of the container
# (hs backup ct authentik on) holds the whole setup.
#   first login   user "akadmin", the password is made here and printed once
#                 (also in /opt/authentik/.env inside the container)
#   you           log in with your AD account: an LDAP source pointing at the
#                 domain controller (dc1); the closing text lists the values
#   friends       local users made in Authentik (Directory -> Users), no AD account
#   Pelican       signs in through Authentik (OIDC), see packages/authentik/guide.md
# The recipe does NOT touch Zoraxy: only the login page of Authentik gets a
# rule (the closing text says which), never an admin page of this server.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# RECIPE_SKIP_PULL=1 (no download of the images and no start: only the compose
# files are written and checked).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-authentik}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 2048 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Docker inside and start Authentik from its official docker-compose.yml (server, worker, database)"
  say "  make the database password, the secret key and the first admin password once (in /opt/authentik/.env)"
  say "  put the container in the nightly backup with a database dump"
  say "  print the values for the LDAP source (your AD accounts) and for the Pelican login"
  exit 0
fi

port_setting "Authentik" 9000
ensure_container "$ct" 2048 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
install_docker

step "Authentik"
in_ct "Fetching Authentik's docker-compose.yml" '
  mkdir -p /opt/authentik && cd /opt/authentik
  curl -fsSL -m 60 -o docker-compose.yml.new https://goauthentik.io/docker-compose.yml
  mv docker-compose.yml.new docker-compose.yml
  # the settings are written once: the database password and the secret key must never change
  if [ ! -s .env ]; then
    pg=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 40 || true)
    key=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 60 || true)
    admin=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20 || true)
    [ -n "$pg" ] && [ -n "$key" ] && [ -n "$admin" ]
    {
      echo "PG_PASS=$pg"
      echo "AUTHENTIK_SECRET_KEY=$key"
      echo "AUTHENTIK_ERROR_REPORTING__ENABLED=false"
      echo "AUTHENTIK_BOOTSTRAP_PASSWORD=$admin"
      echo "AUTHENTIK_BOOTSTRAP_EMAIL=admin@localhost"
      echo "COMPOSE_PORT_HTTP=$1"
      echo "COMPOSE_PORT_HTTPS=9443"
    } > .env.new
    chmod 600 .env.new && mv .env.new .env
  else
    # a later run keeps the secrets and only follows the port
    sed -i "s|^COMPOSE_PORT_HTTP=.*|COMPOSE_PORT_HTTP=$1|" .env
  fi
  docker compose config -q' "$PORT"

pull='cd /opt/authentik && docker compose pull -q'
start='cd /opt/authentik && docker compose up -d --remove-orphans'
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Authentik not started"
else
  in_ct "Downloading Authentik" "$pull"
  in_ct "Starting Authentik" "$start"
  wait_page Authentik 'docker compose -f /opt/authentik/docker-compose.yml logs --tail 50' --path /-/health/live/ --ok --tries 150
  ok "Authentik is running"
fi

step "Backup"
# the database runs in a Docker container of its own: a dump (hs-dump) is made right before each backup
install_dump_tool
backup_with_dump authentik "/usr/local/sbin/hs-dump postgres-compose authentik /opt/authentik postgresql authentik authentik"
ok "$(t "'%s' is in the nightly backup with a database dump (hs backup ct %s off: take it out)" "$ct" "$ct")"

# the values for the closing text
admin_pw=$(incus exec "$ct" -- sed -n 's/^AUTHENTIK_BOOTSTRAP_PASSWORD=//p' /opt/authentik/.env </dev/null 2>/dev/null || true)
# adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }
domain=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' || true)
base_dn=""
if [ -n "$domain" ]; then base_dn="DC=${domain//./,DC=}"; fi
dc_ip=$(address "$(dc_name)" 2>/dev/null || true)

recipe_facts web
kv "Login" "akadmin / ${admin_pw:-?}"
declare_service authentik Authentik authentik never-public Administration "Login: users, groups, applications"
box <<DONE
$(say "The password is also in /opt/authentik/.env inside the container: change it, then keep it safe.")
$(say "1. Your AD account: Directory -> Federation and Social login -> Create -> LDAP Source")
$(t '     Server URI  ldaps://%s    Base DN  %s' "${dc_ip:-10.10.95.40}" "${base_dn:-DC=ad,DC=home,DC=lan}")
$(t '     Bind CN     authentik-bind@%s  (make the user: hs user add authentik-bind)' "${domain:-ad.home.lan}")
$(say "     TLS certificate: leave empty (Samba's is self-signed). Addition User DN / Group DN: CN=Users")
$(say "2. Friends: Directory -> Users -> Create. They need no AD account.")
$(say "3. Zoraxy: a rule only for the login page, with the header  X-Forwarded-Proto: https  and the")
$(say "   virtual directory  /if/admin/  ->  127.0.0.1:1  (a dead end: the admin page stays at home).")
$(docs_hint authentik)
DONE
