#!/usr/bin/env bash
# recipe: Synapse: your own Matrix chat server (Element Synapse), with PostgreSQL
# recipe.de: Synapse: ein eigener Matrix-Chatserver (Element Synapse), mit PostgreSQL
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "synapse", installs Synapse from the
# official Matrix package repository (packages.matrix.org) and PostgreSQL,
# creates an admin user with a random password (/var/lib/hs/synapse-admin).
# Registration stays closed. Federation and Element clients need a public
# address: that is a Zoraxy rule (Matrix API only, never an admin page).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-synapse}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (2048 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install PostgreSQL and Synapse (packages.matrix.org) inside, listening on the chosen port (asks for it, default 80)"
  say "  install Synapse-Admin (admin web page, lighttpd, port asked, default 5173; no Zoraxy rule)"
  say "  put the container in the nightly backup with a database dump"
  say "  ask for the server name (the part after the colon in @user:name, it cannot be changed later)"
  say "  with calls = an address (asked, empty = off): advertise the LiveKit ticket service of hs recipe livekit to clients (Cinny, Element Call) and turn on what Synapse needs for it"
  printf '%s\n' "$(t "  create the admin user 'admin' with a random password in %s/synapse-admin (root only)" "$state")"
  exit 0
fi

port_setting "Synapse" 8008
setting SERVER_NAME "Matrix server name (@user:name, final)" "$(hostname).lan" "$(hostname).lan" "[A-Za-z0-9][A-Za-z0-9.-]*"
setting ADMIN_PORT "Port of the admin page (Synapse-Admin)" 5173 5173 "$a_port"
setting RTC_URL "Calls: address of the LiveKit ticket service, e.g. https://rtc.<your domain> (empty = no calls, see hs recipe livekit)" "" "" "(https://[A-Za-z0-9][A-Za-z0-9.:/-]*)?"
# Suggested public address: matrix.<server name> when the server name is a real domain (not *.lan etc.).
case "$SERVER_NAME" in *.lan|*.local|*.home|*.internal) base_default= ;; *.*) base_default="https://matrix.$SERVER_NAME/" ;; *) base_default= ;; esac
setting PUBLIC_BASEURL "Calls: public address clients reach Synapse at (served in /.well-known/matrix/client)" "$base_default" "$base_default" "(https://[A-Za-z0-9][A-Za-z0-9.:/-]*)?"
[ -z "$RTC_URL" ] || [ -n "$PUBLIC_BASEURL" ] || fail "Calls need the public address of Synapse: RECIPE_PUBLIC_BASEURL=https://matrix.<your domain>/ hs recipe synapse"
ensure_container "$ct" 2048
fixed_address "$ct"
wait_internet "$ct"

step "Install Synapse"
if incus exec "$ct" -- sh -c 'dpkg -s matrix-synapse-py3 >/dev/null 2>&1 && dpkg -s postgresql >/dev/null 2>&1' </dev/null 2>/dev/null; then
  ok "installed already"
else
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing PostgreSQL and tools" '$1 install -y -qq --no-install-recommends postgresql ca-certificates curl lsb-release openssl' "$apt_quick"
  in_ct "Adding the Matrix package repository" '
    curl -fsSL -o /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
    $1 update -qq' "$apt_quick"
  in_ct "Installing Synapse (a few minutes)" '
    echo "matrix-synapse-py3 matrix-synapse/server-name string $2" | debconf-set-selections
    echo "matrix-synapse-py3 matrix-synapse/report-stats boolean false" | debconf-set-selections
    $1 install -y -qq matrix-synapse-py3' "$apt_quick" "$SERVER_NAME"
fi

step "Database and listener"
in_ct "Creating the PostgreSQL database" '
  if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='"'"'synapse_user'"'"'\"" | grep -q 1; then
    pw=$(openssl rand -hex 16)
    su postgres -c "psql -c \"CREATE USER synapse_user WITH PASSWORD '"'"'$pw'"'"'\"" >/dev/null
    su postgres -c "createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse_user synapse"
    cat > /etc/matrix-synapse/conf.d/hs-database.yaml <<YAML
database:
  name: psycopg2
  args:
    user: synapse_user
    password: $pw
    database: synapse
    host: localhost
    cp_min: 5
    cp_max: 10
YAML
    chown matrix-synapse:nogroup /etc/matrix-synapse/conf.d/hs-database.yaml
    chmod 640 /etc/matrix-synapse/conf.d/hs-database.yaml
  fi'
low_ports
in_ct "Setting the port and starting it" '
  # the package makes no shared secret: register_new_matrix_user needs one
  if [ ! -f /etc/matrix-synapse/conf.d/hs-registration.yaml ]; then
    printf "registration_shared_secret: \"%s\"\n" "$(openssl rand -hex 32)" > /etc/matrix-synapse/conf.d/hs-registration.yaml
    chown matrix-synapse:nogroup /etc/matrix-synapse/conf.d/hs-registration.yaml
    chmod 640 /etc/matrix-synapse/conf.d/hs-registration.yaml
  fi
  cat > /etc/matrix-synapse/conf.d/hs-listener.yaml <<YAML
listeners:
  - port: $1
    bind_addresses: ["0.0.0.0"]
    type: http
    tls: false
    x_forwarded: true
    resources:
      - names: [client, federation]
        compress: false
YAML
  chown matrix-synapse:nogroup /etc/matrix-synapse/conf.d/hs-listener.yaml
  systemctl enable -q matrix-synapse
  systemctl restart matrix-synapse' "$PORT"
in_ct "Calls (MatrixRTC)" '
  if [ -n "$1" ]; then
    cat > /etc/matrix-synapse/conf.d/hs-calls.yaml <<YAML
# written by hs recipe synapse: what Element Call / Cinny need before they offer calls
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true
  msc4222_enabled: true
max_event_delay_duration: 24h
public_baseurl: "$2"
# the ticket service (lk-jwt-service) checks logins at the server name; without this it tries port 8448
serve_server_wellknown: true
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: "$1"
extra_well_known_client_content:
  org.matrix.msc4143.rtc_foci:
    - type: livekit
      livekit_service_url: "$1"
YAML
    chown matrix-synapse:nogroup /etc/matrix-synapse/conf.d/hs-calls.yaml
    chmod 640 /etc/matrix-synapse/conf.d/hs-calls.yaml
  else
    rm -f /etc/matrix-synapse/conf.d/hs-calls.yaml
  fi
  systemctl restart matrix-synapse' "$RTC_URL" "$PUBLIC_BASEURL"
note "Synapse $(incus exec "$ct" -- dpkg-query -W -f '${Version}' matrix-synapse-py3 </dev/null 2>/dev/null || _tr "installed")"
wait_page Synapse 'journalctl -u matrix-synapse' --path /_matrix/client/versions --ok --plain --tries 90

step "Synapse-Admin (admin web page)"
in_ct "Installing it with a small web server" '
  $1 install -y -qq --no-install-recommends lighttpd >/dev/null
  if [ ! -f /var/www/synapse-admin/index.html ]; then
    url=$(curl -fsSL https://api.github.com/repos/Awesome-Technologies/synapse-admin/releases/latest | sed -n "s/.*\"browser_download_url\": \"\(.*\.tar\.gz\)\".*/\1/p" | head -n1)
    [ -n "$url" ]
    rm -rf /var/www/synapse-admin; mkdir -p /var/www/synapse-admin
    curl -fsSL "$url" | tar xz -C /var/www/synapse-admin --strip-components=1
  fi
  sed -i -e "s|^server.document-root .*|server.document-root = \"/var/www/synapse-admin\"|" -e "s|^server.port .*|server.port = $2|" /etc/lighttpd/lighttpd.conf
  systemctl enable -q lighttpd
  systemctl restart lighttpd' "$apt_quick" "$ADMIN_PORT"

step "Admin login"
mkdir -p "$state"
if [ "$(secret_state "$state/synapse-admin")" = locked ]; then
  vault_locked_note >&2; exit 1
fi
if [ -s "$state/synapse-admin" ]; then
  ok "$(t 'Kept as it is (password in %s/synapse-admin)' "$state")"
else
  pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
  secret_prepare synapse-admin "$state" || exit 1
  incus exec "$ct" -- register_new_matrix_user -u admin -p "$pw" -a \
    -c /etc/matrix-synapse/conf.d/hs-registration.yaml "http://127.0.0.1:$PORT" >/dev/null </dev/null ||
    fail "$(t "Could not create the admin user. If it exists already, set its password with: incus exec %s -- hash_password" "$ct")"
  ( umask 077; printf 'user: @admin:%s\npassword: %s\n' "$SERVER_NAME" "$pw" > "$state/synapse-admin" )
  ok "$(t 'Admin user created, password stored in %s/synapse-admin (root only)' "$state")"
fi

step "Backup"
# PostgreSQL runs inside the container: a dump (hs-dump) is made right before each backup; the media files of Synapse are plain files and go along
install_dump_tool
backup_with_dump synapse "/usr/local/sbin/hs-dump postgres synapse synapse"
ok "$(t "'%s' is in the nightly backup with a database dump (hs backup ct %s off: take it out)" "$ct" "$ct")"

declare_service synapse Synapse synapse private-ok Apps "Matrix chat server"
box <<DONE
$(t 'Done. Synapse answers at   %s' "$(web)")
$(t '  Matrix ID of the admin:  @admin:%s' "$SERVER_NAME")
$(t '  Admin page (Synapse-Admin):  http://%s:%s   (enter the Synapse address above as homeserver URL)' "$ip" "$ADMIN_PORT")
$(t '  sudo cat %s/synapse-admin' "$state")
$(say "  1. Log in with a Matrix client (Element, or any other) and set the server to the address above.")
$(say "  2. Registration is closed (new users, public address and federation: see the guide). Never give an admin page a rule.")
$([ -z "$RTC_URL" ] || t "  3. Calls: clients find %s through https://<server name>/.well-known/matrix/client, so that path must reach Synapse (Zoraxy: Matrix API rule). Check: curl https://<server name>/.well-known/matrix/client" "$RTC_URL")
$(docs_hint containers-and-apps)
DONE
