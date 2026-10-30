#!/usr/bin/env bash
# recipe: Matrix hook: Radarr, Sonarr, Seerr, the duplicate cleanup and SABnzbd post their events to a Matrix room (needs Synapse)
# recipe.de: Matrix-Hook: Radarr, Sonarr, Seerr, die Bereinigung doppelter Filme und SABnzbd melden ihre Ereignisse in einem Matrix-Raum (braucht Synapse)
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: installs a small webhook receiver (packages/matrix-hook/hs-matrix-hook.py and
# matrix-card/) into the container "synapse" as the service hs-matrix-hook, creates the Matrix
# user hs-bot and writes the secret address to /var/lib/hs/matrix-hook. Radarr, Sonarr and Seerr
# send a Webhook to http://<synapse>:<port>/hook/<secret>/<room>; the room (default "media") is
# made on first use and the owner is invited. Every event becomes a notification card (a 1800x600
# PNG drawn with Pillow, fonts included in matrix-card/fonts; the poster is fetched from the
# payload's address); without Pillow, or if a card fails, a markdown message is sent instead.
# The owner types commands (help, clear, status, test, mute: matrix-card/bot.py) in a chat of their own with the
# bot ("Homeserver bot", made at the start, an unencrypted direct chat); the message rooms are read-only for the owner.
# Rooms are not encrypted (a bot without E2EE). Never a Zoraxy rule.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-synapse}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  use the container '%s' (hs recipe synapse first), install the webhook receiver there as the service hs-matrix-hook" "$ct")"
  printf '%s\n' "$(t "  create the Matrix user 'hs-bot' and a secret address, stored in %s/matrix-hook (root only)" "$state")"
  say "  post no test card; the room 'media' is made with the first message and the owner is invited; every event is a card with the poster (Pillow, fonts included)"
  say "  print the webhook address for Radarr, Sonarr and Seerr"
  exit 0
fi

incus info "$ct" >/dev/null 2>&1 || fail "$(t "The container '%s' does not exist. Install Synapse first: hs recipe synapse" "$ct")"
[ "$(incus query "/1.0/instances/$ct" | jq -r .status)" = Running ] || fail "$(t "The container '%s' is not running (hs ct %s start)" "$ct" "$ct")"
ip=$(address "$ct")
[ -n "$ip" ] || fail "$(t "'%s' has no address. Check the network (hs ct list)." "$ct")"

conf_value() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | tail -n1 || true; }
syn_port=$(conf_value PORT); syn_port=${syn_port:-8008}
server_name=$(conf_value SERVER_NAME); server_name=${server_name:-$(hostname).lan}
hook_ports='[1-9][0-9]{3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]'
setting HOOK_PORT "Port of the webhook receiver" 8090 8090 "$hook_ports"
setting HOOK_ROOM "Room for the messages (a-z, 0-9, -)" media media "[a-z0-9][a-z0-9-]{0,31}"
setting CARD_WIDTH "Width of the cards in the chat (900 = normal, 1350 = 1.5 times as large)" 900 900 "[3-9][0-9]{2}|1[0-7][0-9]{2}|1800"
setting HOOK_OWNER "Matrix ID that is invited to the room" "@admin:$server_name" "@admin:$server_name" "@[A-Za-z0-9._=/-]+:[A-Za-z0-9.-]+"

step "Webhook receiver"
in_ct "Checking Python and Pillow" '$1 update -qq && $1 install -y -qq --no-install-recommends python3-minimal python3-pil fonts-dejavu-core ca-certificates' "$apt_quick"
in_ct "Creating the service user" 'id hs-hook >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hs-hook'
in_ct "Making the program folder" 'rm -rf /usr/local/lib/hs-matrix-hook /usr/local/bin/hs-matrix-hook; mkdir -p /usr/local/lib/hs-matrix-hook'
spin "Copying the program" bash -c 'incus file push -q --mode 0755 "$1/hs-matrix-hook.py" "$2/usr/local/lib/hs-matrix-hook/hs-matrix-hook.py" &&
  incus file push -q -r "$3/files/matrix-card" "$2/usr/local/lib/hs-matrix-hook/"' _ "$(dirname "$0")" "$ct" "$scripts/recipes"

step "Bot user and secret"
mkdir -p "$state"
if [ "$(secret_state "$state/matrix-hook")" = locked ]; then
  vault_locked_note >&2; exit 1
fi
hook_value() { awk -v k="$1:" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$state/matrix-hook" 2>/dev/null || true; }
if [ -s "$state/matrix-hook" ]; then
  ok "$(t 'Kept as it is (in %s/matrix-hook)' "$state")"
else
  secret=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
  secret_prepare matrix-hook "$state" || exit 1
  incus exec "$ct" -- register_new_matrix_user -u hs-bot -p "$pw" --no-admin \
    -c /etc/matrix-synapse/conf.d/hs-registration.yaml "http://127.0.0.1:$syn_port" >/dev/null </dev/null ||
    fail "$(t "Could not create the user hs-bot. If it exists already, remove it in the admin page (Synapse-Admin) and run this again.")"
  ( umask 077; printf 'secret: %s\nuser: @hs-bot:%s\npassword: %s\n' "$secret" "$server_name" "$pw" > "$state/matrix-hook" )
  ok "$(t 'Bot user created, secret and password stored in %s/matrix-hook (root only)' "$state")"
fi
secret=$(hook_value secret); pw=$(hook_value password); bot=$(hook_value user)
[ -n "$secret" ] && [ -n "$pw" ] || fail "$(t "%s/matrix-hook is incomplete. Remove the file and the user hs-bot, then run this again." "$state")"

step "Rate limit of the bot"
# Synapse lets an ordinary user send only a few events a second; deleting a long history message by message
# would take hours. The admin login of the synapse recipe lifts the limit for hs-bot only (no admin rights for it).
admin_pw=$(awk '$1 == "password:" { print $2; exit }' "$state/synapse-admin" 2>/dev/null || true)
if [ -n "$admin_pw" ]; then
  in_ct "Lifting the limit for hs-bot, so a big clear is quick" '
    api="http://127.0.0.1:$1"
    tok=$(curl -fsS -X POST "$api/_matrix/client/v3/login" -H "Content-Type: application/json" \
      -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"admin\"},\"password\":\"$2\"}" |
      python3 -c "import json,sys;print(json.load(sys.stdin)[\"access_token\"])")
    curl -fsS -X POST "$api/_synapse/admin/v1/users/$3/override_ratelimit" -H "Authorization: Bearer $tok" \
      -H "Content-Type: application/json" -d "{\"messages_per_second\":0,\"burst_count\":0}" >/dev/null
    curl -fsS -X POST "$api/_matrix/client/v3/logout" -H "Authorization: Bearer $tok" >/dev/null || true' "$syn_port" "$admin_pw" "$bot" ||
    warn "$(t "Could not lift the rate limit of hs-bot. A big clear will work, but slowly.")"
else
  warn "$(t "No admin login in %s/synapse-admin, so the rate limit of hs-bot stays. A big clear will work, but slowly." "$state")"
fi

step "Starting it"
cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT
# the time on the cards is the server's local time
tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)
printf '{"homeserver":"http://127.0.0.1:%s","bot_user":"%s","bot_password":"%s","owner":"%s","secret":"%s","port":%s,"bind":"0.0.0.0","timezone":"%s","card_width":%s}\n' \
  "$syn_port" "$bot" "$pw" "$HOOK_OWNER" "$secret" "$HOOK_PORT" "$tz" "$CARD_WIDTH" > "$cfg"
spin "Writing the settings" incus file push -q --mode 0640 --gid "$(incus exec "$ct" -- id -g hs-hook </dev/null)" "$cfg" "$ct/etc/hs-matrix-hook.json"
in_ct "Installing the service" '
  cat > /etc/systemd/system/hs-matrix-hook.service <<UNIT
[Unit]
Description=Webhooks (Radarr, Sonarr, Seerr) into a Matrix room
After=network-online.target matrix-synapse.service
Wants=network-online.target

[Service]
User=hs-hook
StateDirectory=hs-matrix-hook
ExecStart=/usr/bin/python3 /usr/local/lib/hs-matrix-hook/hs-matrix-hook.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q hs-matrix-hook
  systemctl restart hs-matrix-hook'
hook="http://$ip:$HOOK_PORT"
spin "Waiting for it to answer" bash -c 'for _ in $(seq 1 30); do curl -fsS -m 3 -o /dev/null "$1/healthz" 2>/dev/null && exit 0; sleep 1; done; exit 1' _ "$hook" ||
  fail "$(t 'The receiver does not answer at %s. Look at: incus exec %s -- journalctl -u hs-matrix-hook' "$hook" "$ct")"

step "Cards"
curl -fsS -m 5 "$hook/healthz" 2>/dev/null | grep -q '"cards": true' || warn "Cards are off: Pillow is missing or switched off, the room gets text messages."

# the helpers of the film containers (dedupe job, SABnzbd's script) learn the address
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
for c in radarr:/usr/local/lib/hs sabnzbd:/opt/sabnzbd/config/scripts; do
  if incus info "${c%%:*}" >/dev/null 2>&1 && incus exec "${c%%:*}" -- test -d "${c#*:}" </dev/null 2>/dev/null; then
    ( ct=${c%%:*}; media_notify_conf "$ct" "${c#*:}" "$([ "$ct" = sabnzbd ] && echo lookup)" ) || warn "$(t "Could not tell '%s' the Matrix address. Run its recipe again." "${c%%:*}")"
  fi
done

url="$hook/hook/$secret/$HOOK_ROOM"
box <<DONE
$(t 'Done. The room "%s" is made with the first message, then %s gets an invitation (accept it in Element). No test card is posted: type  test  in the chat "Homeserver bot" to try it.' "$HOOK_ROOM" "$HOOK_OWNER")
$(t 'Webhook address (the secret is part of it, no Zoraxy rule):  %s' "$url")

$(say "The few clicks that cannot wait:")
$(say "  1. Radarr and Sonarr: Settings -> Connect -> + -> Webhook, Method POST, the address above.")
$(say "     Triggers: On Grab, On Import, On Upgrade, On Health Issue, On Health Restored. Test sends a message.")
$(say "  2. Seerr: Settings -> Notifications -> Webhook, Webhook URL = the address above, keep the JSON payload as it is.")
$(say "     Enable: Request Approved and Request Automatically Approved.")
$(say "  Maintainerr (Script) and SABnzbd need no click: their helpers got this address (hs recipe radarr / sabnzbd run again if they were installed before).")
$(say "  3. Accept the second invitation too, the chat 'Homeserver bot', and type  help  there: the commands (clear, status, test, mute) work in it for your Matrix ID only.")
$(say "     The room for the messages is read-only for you (you can still delete and react).")
$(docs_hint containers-and-apps)
DONE
