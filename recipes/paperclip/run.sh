#!/usr/bin/env bash
# recipe: Paperclip: a team of AI agents (Claude Code, local models) with tickets, budgets and an audit trail
# recipe.de: Paperclip: ein Team aus KI-Agenten (Claude Code, lokale Modelle) mit Tickets, Budgets und Protokoll
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "paperclip", installs Node.js 24, Paperclip (paperclipai), the Claude Code CLI, the Pi CLI and
# the GitHub CLI, and starts Paperclip with the system as the unprivileged user "paperclip" in the mode "authenticated" (login required).
# Optional: an Anthropic key and a GitHub token (typed, not shown, written only into /etc/paperclip/env inside the container, mode 0600),
# and the address of an Ollama server (for example the gaming PC) that the agent type "Pi" gets as a provider.
# No Zoraxy rule: it is an admin page, and its agents run shell commands.
# What it deliberately does not do: put /bulk, the Incus socket or any host path into the container.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-paperclip}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Node.js 24, Paperclip, the Claude Code and Pi CLIs and the GitHub CLI inside, run by systemd as the user paperclip (asks for the port, default 3100)"
  say "  optionally store an Anthropic key and a GitHub token inside the container (0600) and set up an Ollama server as provider for Pi"
  exit 0
fi

port_setting "Paperclip" 3100 3100
setting PCVER "Paperclip version (npm: a number like 1.2.3, or latest)" latest latest '[A-Za-z0-9._-]+'
setting OLLAMA "Address of an Ollama server for local models (http://host:11434, or - for none)" - - '-|https?://[A-Za-z0-9._:-]+'
setting OLLAMA_MODEL "Ollama model for the coding agents" "qwen3-coder:30b" "qwen3-coder:30b" '[A-Za-z0-9._:/-]+'
ensure_container "$ct" 4096
fixed_address "$ct"
wait_internet "$ct"
low_ports   # the program runs as an ordinary user; below port 1024 it would silently pick another port

step "Install the tools"
in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
in_ct "Installing git, the GitHub CLI and a compiler" '$1 install -y -qq --no-install-recommends git gh ca-certificates curl xz-utils openssh-client python3 build-essential' "$apt_quick"
# Paperclip needs Node.js 24 or newer; Debian has 20 (npm then fails with "Cannot read properties of null (reading 'edgesOut')"),
# so the official tarball goes to /usr/local/lib/nodejs, checked against nodejs.org's SHA256SUMS.
if incus exec "$ct" -- sh -c 'test "$(node -p "process.versions.node.split(\".\")[0]" 2>/dev/null || echo 0)" -ge 24' </dev/null 2>/dev/null; then
  ok "Node.js 24 or newer is installed already"
else
  in_ct "Installing Node.js 24 from nodejs.org" '
    cd /tmp
    base=https://nodejs.org/dist/latest-v24.x
    curl -fsSL -m 60 "$base/SHASUMS256.txt" -o node-sums
    f=$(grep -o "node-v[0-9.]*-linux-x64.tar.xz" node-sums | head -n1)
    curl -fsSL -m 300 "$base/$f" -o "$f"
    grep " $f\$" node-sums | sha256sum -c -
    rm -rf /usr/local/lib/nodejs; mkdir -p /usr/local/lib/nodejs
    tar -xJf "$f" -C /usr/local/lib/nodejs --strip-components=1
    for b in node npm npx; do ln -sf /usr/local/lib/nodejs/bin/$b /usr/local/bin/$b; done
    npm config set prefix /usr/local --location=global
    rm -f "$f" node-sums'
fi
# npm 11 skips install scripts unless they are allowed; these packages need theirs (embedded database, native binaries)
in_ct "Installing Paperclip, Claude Code and Pi (a few minutes)"   'cd /tmp; npm install -g --no-fund --no-audit --allow-scripts=@anthropic-ai/claude-code,@embedded-postgres/linux-x64,ssh2,protobufjs,cpu-features "paperclipai@$1" @anthropic-ai/claude-code @earendil-works/pi-coding-agent' "$PCVER"
in_ct "Creating the user paperclip" '
  id paperclip >/dev/null 2>&1 || useradd -m -d /var/lib/paperclip -s /bin/bash paperclip
  install -d -o paperclip -g paperclip -m 0750 /var/lib/paperclip /var/lib/paperclip/repos
  install -d -m 0755 /etc/paperclip'
note "Paperclip $(incus exec "$ct" -- sh -c 'npm ls -g --depth=0 paperclipai 2>/dev/null | sed -n "s/.*paperclipai@//p"' </dev/null 2>/dev/null || true)"

step "Settings and keys"
# The environment file lives only inside the container. A key typed here goes through a temporary file with mode 0600, never through argv.
if incus exec "$ct" -- test -f /etc/paperclip/env </dev/null 2>/dev/null; then
  ok "settings exist already, keeping them (keys: edit /etc/paperclip/env inside the container)"
  env_new=false
else
  env_new=true
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  {
    echo "BETTER_AUTH_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    if interactive; then
      k=$(ask_secret "Anthropic API key for Claude Code (not shown, enter = none, log in by hand later):" || true)
      [ -z "$k" ] || echo "ANTHROPIC_API_KEY=$k"
      g=$(ask_secret "GitHub token that may only push branches and open pull requests (not shown, enter = none):" || true)
      [ -z "$g" ] || echo "GH_TOKEN=$g"
    fi
  } > "$tmp"
  incus file push -q --mode 0600 --uid 0 --gid 0 "$tmp" "$ct/etc/paperclip/env"
  rm -f "$tmp"; trap - EXIT
  ok "settings written inside the container (mode 0600)"
fi

if [ "$OLLAMA" != - ]; then
  step "Local models (Ollama at $OLLAMA)"
  # The adapter "Pi" (pi_local) reaches Ollama: Pi reads custom providers from models.json. Paperclip's environment test and its model
  # list read ~paperclip/.pi/agent/models.json; real agent runs use PAPERCLIP_PI_PROVIDERS (same content). Every model Ollama has is
  # registered (without ":latest"); when it does not answer, the one named in the preference.
  models=$(incus exec "$ct" -- curl -fsS -m 5 "${OLLAMA%/}/api/tags" </dev/null 2>/dev/null | jq -c '[.models[].name | sub(":latest$"; "") | {id: .}]' 2>/dev/null || true)
  [ -n "$models" ] && [ "$models" != "[]" ] || models=$(jq -cn --arg m "$OLLAMA_MODEL" '[{id: $m}]')
  provider=$(jq -cn --arg url "${OLLAMA%/}/v1" --argjson m "$models" '{ollama: {baseUrl: $url, api: "openai-completions", apiKey: "ollama", models: $m}}')
  cfg=$(mktemp)
  jq -n --argjson p "$provider" '{providers: $p}' > "$cfg"
  incus exec "$ct" -- install -d -o paperclip -g paperclip -m 0750 /var/lib/paperclip/.pi /var/lib/paperclip/.pi/agent </dev/null
  incus file push -q --mode 0640 --uid "$(incus exec "$ct" -- id -u paperclip </dev/null)" --gid "$(incus exec "$ct" -- id -g paperclip </dev/null)" "$cfg" "$ct/var/lib/paperclip/.pi/agent/models.json"
  rm -f "$cfg"
  # the same providers for real runs; the file holds one KEY=value per line, JSON on one line and without quotes around it
  envtmp=$(mktemp)
  incus file pull -q "$ct/etc/paperclip/env" "$envtmp"
  { grep -v '^PAPERCLIP_PI_PROVIDERS=' "$envtmp" || true; echo "PAPERCLIP_PI_PROVIDERS=$provider"; } > "$envtmp.new"
  incus file push -q --mode 0600 --uid 0 --gid 0 "$envtmp.new" "$ct/etc/paperclip/env"
  rm -f "$envtmp" "$envtmp.new"
  ok "$(t 'Models registered: %s' "$(jq -r 'map(.id) | join(", ")' <<<"$models")")"
  if incus exec "$ct" -- curl -fsS -m 5 -o /dev/null "${OLLAMA%/}/api/tags" </dev/null 2>/dev/null; then
    ok "Ollama answers"
  else
    warn "$(t 'The container cannot reach %s now. Is the PC on, and does Ollama listen on the network (OLLAMA_HOST)? A container has no Tailscale: use the PC address on the LAN, or put Tailscale into this container.' "$OLLAMA")"
  fi
fi

step "First setup of Paperclip"
# `paperclipai run` refuses to start without a config, and only `onboard` writes it. `onboard --yes` also starts the server, prints a
# one-time invite for the first administrator and then keeps running: wait for the invite, note it, stop it (the service takes over).
in_ct "Creating the configuration and the first invite (a minute)" '
  d=/var/lib/paperclip/data/instances/default
  [ -f $d/config.json ] && exit 0
  set -a; . /etc/paperclip/env; set +a
  export HOME=/var/lib/paperclip PAPERCLIP_HOME=/var/lib/paperclip/data PAPERCLIP_TELEMETRY_DISABLED=1
  log=/var/lib/paperclip/onboard.log
  : > $log; chown paperclip $log; chmod 600 $log
  runuser -p -u paperclip -- paperclipai onboard --yes --bind lan --no-install-service -d /var/lib/paperclip/data </dev/null >$log 2>&1 &
  for _ in $(seq 1 90); do grep -q "Invite URL" $log && break; sleep 2; done
  grep -q "Invite URL" $log || { sed -r "s/\x1b\[[0-9;]*m//g" $log | tail -n 15; exit 1; }
  sed -r "s/\x1b\[[0-9;]*m//g" $log | grep -o "/invite/pcp_bootstrap_[A-Za-z0-9]*" | tail -n1 > /var/lib/paperclip/bootstrap-invite
  chown paperclip /var/lib/paperclip/bootstrap-invite; chmod 600 /var/lib/paperclip/bootstrap-invite
  pkill -TERM -u paperclip -f "paperclipai onboard" || true
  for _ in $(seq 1 30); do pgrep -u paperclip >/dev/null || break; sleep 1; done
  rm -f $log'

step "Start Paperclip with the system"
host_name=$(hostname)
in_ct "Writing the service" '
  cat > /etc/systemd/system/paperclip.service <<UNIT
[Unit]
Description=Paperclip
After=network-online.target
Wants=network-online.target

[Service]
User=paperclip
WorkingDirectory=/var/lib/paperclip
EnvironmentFile=/etc/paperclip/env
Environment=HOME=/var/lib/paperclip
Environment=PAPERCLIP_HOME=/var/lib/paperclip/data
Environment=HOST=0.0.0.0
Environment=PORT=$1
Environment=PAPERCLIP_DEPLOYMENT_MODE=authenticated
Environment=PAPERCLIP_ALLOWED_HOSTNAMES=$2,$2.local,$3
Environment=PAPERCLIP_PUBLIC_URL=http://$3:$1
Environment=PAPERCLIP_TELEMETRY_DISABLED=1
ExecStart=/usr/bin/env paperclipai run
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q paperclip
  systemctl restart paperclip' "$PORT" "$ct" "$ip"
wait_page Paperclip 'journalctl -u paperclip' --tries 90

# every start prints a fresh invite while nobody has claimed the instance: the newest one in the log is the one that works
invite=$(incus exec "$ct" -- journalctl -u paperclip --no-pager -n 300 </dev/null 2>/dev/null | grep -o '/invite/pcp_bootstrap_[A-Za-z0-9]*' | tail -n1 || true)

declare_service paperclip "Paperclip" robot never-public Tools "AI agents"
recipe_facts web
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  1. Become the administrator with the one-time invite (valid 3 days, treat it as a password):")
$([ -z "$invite" ] && echo "       incus exec $ct -- journalctl -u paperclip | grep invite" || echo "       $(web)$invite")
$(say "  2. Add an agent with the adapter Claude Code (claude_local); without an API key log in once:")
$(say "       incus exec $ct -- su - paperclip -c 'claude'")
$(say "  3. Set a monthly budget on every agent before the first task.")
$(docs_hint containers-and-apps)
DONE
