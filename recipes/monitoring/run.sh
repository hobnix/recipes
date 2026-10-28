#!/usr/bin/env bash
# recipe: Prometheus (on the server), Grafana and Loki: history of load, disks, pools, containers, and the server's logs
# recipe.de: Prometheus (auf dem Server), Grafana und Loki: Verlauf von Last, Platten, Pools, Containern und die Logs des Servers
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does:
#   on the server   switches on the small programs that hand out the numbers
#                   (`metrics = true` in machine.toml, then a rebuild), the
#                   numbers Incus has about every container, and Prometheus
#                   itself (NixOS service, 127.0.0.1:9090, data on the system
#                   disk, metricsDays/metricsMaxGB): it keeps collecting while
#                   the storage is locked and Incus is down
#   container       "monitoring": Grafana draws the numbers, with dashboards
#                   already in place. It reaches the server's Prometheus through
#                   an Incus proxy device (listens on 127.0.0.1:9090 INSIDE the
#                   container, connects to the host's 127.0.0.1:9090): nothing
#                   new listens on the network, no firewall change.
#                   An older container with its own Prometheus gets it stopped
#                   and disabled (its data stays, nothing is deleted).
#                 Loki keeps the server's logs (kernel, samba, zfs, hs-* units),
#                 Grafana searches them; the dashboard "Errors" shows errors per unit
# Logs, how they get from the server to Loki: the server has NO address on the
# container network (by design), so nothing is pushed from the server and no
# rebuild is needed. Instead the server's /var/log/journal (persistent,
# root:systemd-journal 0640) is shown to the container as a read-only disk
# device and Grafana Alloy (promtail's successor; the promtail release binary
# has no journal support) inside the container reads it. The journal files get
# a read-only ACL for the container's group (setfacl, as root); mapping the
# journal group into the container would need a NixOS rebuild (subgid).
# `hs health` stays the alarm; this is for looking at how things develop.
# No Zoraxy rule: Grafana is an admin page, reachable at home or through Tailscale.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-monitoring}
days=${RECIPE_DAYS:-30}                 # how long the history is kept
machine=${HS_MACHINE_FILE:-/etc/nixos/machine.toml}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  add 'metrics = true' to %s and rebuild, unless the server hands out numbers already" "$machine")"
  say "  let Incus hand out numbers about the containers on port 8444"
  printf '%s\n' "$(t "  create the container '%s' (1536 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  show the server's journal (/var/log/journal) to '%s' read-only (read-only; ACL for the container's group)" "$ct")"
  say "  let the server run Prometheus itself (127.0.0.1:9090, on the system disk; machine.toml: metricsDays, metricsMaxGB)"
  printf '%s\n' "$(t "  connect '%s' to it with a proxy device and stop a Prometheus of its own, if it has one (its data stays)" "$ct")"
  printf '%s\n' "$(t '  install Loki (%s days) with Alloy reading the journal, and Grafana, with five dashboards' "$days")"
  printf '%s\n' "$(t "  store Grafana's admin password in %s/grafana-admin (root only)" "$state")"
  exit 0
fi

step "Numbers from the server"
if [ -n "${RECIPE_SKIP_HOST:-}" ]; then
  note "skipped (RECIPE_SKIP_HOST)"
else
  if curl -fsS -m 3 -o /dev/null http://127.0.0.1:9100/metrics 2>/dev/null && curl -fsS -m 3 -o /dev/null http://127.0.0.1:9633/metrics 2>/dev/null &&
     curl -fsS -m 3 -o /dev/null http://127.0.0.1:9090/-/ready 2>/dev/null; then
    ok "The server hands out and collects its numbers already"
  else
    machine_set metrics true recipe || true
    [ "$(machine_get metrics 2>/dev/null)" = true ] || fail "$(t "Could not add 'metrics = true' to %s. Add it by hand, run hs rebuild, then this recipe again." "$machine")"
    ok "$(t "Added 'metrics = true' to %s" "$machine")"
    spin "Rebuilding the system (a few minutes)" nixos-rebuild switch
    spin "Waiting for the numbers" bash -c 'for _ in $(seq 1 30); do curl -fsS -m 3 -o /dev/null http://127.0.0.1:9100/metrics && curl -fsS -m 3 -o /dev/null http://127.0.0.1:9090/-/ready && exit 0; sleep 1; done; exit 1' ||
      fail "$(t 'The server still hands out no numbers. Look at: systemctl status prometheus-node-exporter prometheus')"
  fi
  # what Incus knows about every instance: CPU, memory, disk, network
  [ "$(incus config get core.metrics_address)" = ":8444" ] || incus config set core.metrics_address :8444
  [ "$(incus config get core.metrics_authentication)" = false ] || incus config set core.metrics_authentication false
  ok "Incus hands out the numbers of the containers on port 8444"
  # first numbers of this server's own checks (problems, age of the parity)
  bash "$scripts/health-check.sh" --dry-run >/dev/null 2>&1 || true
fi

port_setting "Grafana" 3000
setting DAYS "Days of history to keep" "${RECIPE_DAYS:-30}" "${RECIPE_DAYS:-30}" "$a_number"
days=$DAYS
if [ -z "${RECIPE_SKIP_HOST:-}" ]; then
  # Prometheus on the server keeps what machine.toml says (metricsDays, default 30): follow the answer
  cur=$(machine_get metricsDays 2>/dev/null || true)
  if [ "${cur:-30}" != "$days" ]; then
    machine_set metricsDays "$days" recipe || true
    [ "$(machine_get metricsDays 2>/dev/null)" = "$days" ] || fail "$(t "Could not set 'metricsDays = %s' in %s. Set it by hand, run hs rebuild, then this recipe again." "$days" "$machine")"
    ok "$(t "Set 'metricsDays = %s' in %s" "$days" "$machine")"
    spin "Rebuilding the system (a few minutes)" nixos-rebuild switch
  fi
fi
# Logs are opt-in: the recipe changes who may read the server's journal (an ACL for the container's
# group) and Grafana, which shows dashboards without a login, then shows error lines. A container that
# existed before this question keeps "no" until `hs recipe monitoring --ask`.
setting LOGS "Also collect the server's logs (kernel, Samba, disks, errors) so Grafana can search them? Gives this container read access to the server's journal. yes or no" yes no "yes|no"
ensure_container "$ct" 1536

step "Prometheus of the server"
# An older container ran its own Prometheus on 127.0.0.1:9090: stop it first, the proxy device needs that port.
if incus exec "$ct" -- sh -c 'systemctl is-enabled prometheus >/dev/null 2>&1 || systemctl is-active prometheus >/dev/null 2>&1' </dev/null; then
  in_ct "Stopping the Prometheus inside the container (the server runs it now)" 'systemctl disable --now prometheus'
  note "$(t "The old Prometheus of '%s' is stopped and disabled. Its data stays in /var/lib/prometheus inside the container (delete it yourself when you do not need it)." "$ct")"
fi
if incus config device get "$ct" prometheus connect >/dev/null 2>&1; then
  ok "The container reaches the server's Prometheus already"
else
  incus config device add "$ct" prometheus proxy listen=tcp:127.0.0.1:9090 connect=tcp:127.0.0.1:9090 bind=instance >/dev/null ||
    fail "$(t "Could not add the proxy device 'prometheus' to '%s'." "$ct")"
  ok "$(t "'%s' reaches the server's Prometheus at 127.0.0.1:9090 (proxy device, nothing new listens on the network)" "$ct")"
fi

step "Journal of the server"
jdir=${HS_JOURNAL_DIR:-/var/log/journal}
jgid=62                                  # the group Alloy reads the journal as, inside the container
logs=1
[ "$LOGS" = yes ] || logs=0
# which group id on the server is group $jgid of the container (e.g. 1000062)
hgid=$(incus config get "$ct" volatile.idmap.current | jq -r --argjson g "$jgid" '[.[] | select(.Isgid and .Nsid <= $g and $g < .Nsid + .Maprange)][0] | if . then .Hostid + $g - .Nsid else empty end' 2>/dev/null || true)
if [ "$LOGS" != yes ]; then
  note "Logs are off (hs recipe monitoring --ask to switch them on)."
elif [ ! -d "$jdir" ]; then
  warn "$(t 'No persistent journal at %s: logs are skipped (Storage=persistent in journald.conf, then run this again).' "$jdir")"
  logs=0
elif [ -z "$hgid" ]; then
  warn "$(t "Could not work out the group mapping of '%s': logs are skipped." "$ct")"
  logs=0
else
  # Journal files are root:systemd-journal 0640 and that group does not exist in
  # an unprivileged container. A read-only ACL for the container's group (and
  # as default for new journal files) lets it read, nothing else changes.
  find "$jdir" -type d -exec setfacl -m "g:$hgid:r-x" -m "d:g:$hgid:r-x" {} + ||
    fail "$(t "Could not set the read access for '%s' on %s (needs root; setfacl)." "$ct" "$jdir")"
  find "$jdir" -type f -exec setfacl -m "g:$hgid:r--" {} +
  incus config device get "$ct" hs-journal source >/dev/null 2>&1 ||
    incus config device add "$ct" hs-journal disk source="$jdir" path=/var/log/host-journal readonly=true >/dev/null
  ok "$(t "The journal is shown to '%s' (read-only, through an ACL for group %s)" "$ct" "$hgid")"
fi

fixed_address "$ct"
wait_internet "$ct"

step "Install Grafana"
if incus exec "$ct" -- sh -c 'command -v grafana-server' >/dev/null 2>&1 </dev/null; then
  ok "installed already"
else
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing curl" '$1 install -y -qq --no-install-recommends curl ca-certificates gnupg' "$apt_quick"
  in_ct "Adding the Grafana package source" '
    mkdir -p /etc/apt/keyrings
    curl -fsSL -m 60 https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    $1 update -qq' "$apt_quick"
  in_ct "Installing Grafana (about 130 MB)" '$1 install -y -qq grafana' "$apt_quick"
fi
note "Grafana $(incus exec "$ct" -- dpkg-query -W -f '${Version}' grafana </dev/null)"

if [ "$logs" = 1 ]; then
  step "Install Loki and Alloy"
  if incus exec "$ct" -- sh -c 'command -v loki && command -v alloy' >/dev/null 2>&1 </dev/null; then
    ok "installed already"
  else
    in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
    in_ct "Installing Loki and Alloy" '$1 install -y -qq loki alloy' "$apt_quick"
  fi
  note "Loki $(incus exec "$ct" -- dpkg-query -W -f '${Version}' loki </dev/null), Alloy $(incus exec "$ct" -- dpkg-query -W -f '${Version}' alloy </dev/null)"
fi

step "Configure"
incus file push -q "$(dirname "$0")/homeserver-dashboard.json" "$ct/tmp/homeserver.json"
incus file push -q "$(dirname "$0")/errors-dashboard.json" "$ct/tmp/errors.json"
if [ "$logs" = 1 ]; then
  in_ct "$(t 'Loki and Alloy: store, read the journal, keep %s days' "$days")" '
days=$1; name=$2; jgid=$3
# write a file only when it changes; returns 1 when it stayed as it was
put() { cat > "$1.new"; if cmp -s "$1.new" "$1" 2>/dev/null; then rm -f "$1.new"; return 1; fi; mv "$1.new" "$1"; }
changed=0
mkdir -p /var/lib/loki; chown loki /var/lib/loki
# the group Alloy reads the journal as (its id is the one the server gave the ACL to)
getent group hs-journal >/dev/null || groupadd -g "$jgid" hs-journal
put /etc/loki/config.yml <<YML && changed=1 || true
# Written by "hs recipe monitoring". Edits here are overwritten.
auth_enabled: false
server:
  http_listen_address: 127.0.0.1
  http_listen_port: 3100
  grpc_listen_address: 127.0.0.1
  grpc_listen_port: 9096
  log_level: warn
common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  replication_factor: 1
  ring: { kvstore: { store: inmemory } }
  storage:
    filesystem: { chunks_directory: /var/lib/loki/chunks, rules_directory: /var/lib/loki/rules }
schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index: { prefix: index_, period: 24h }
compactor:
  working_directory: /var/lib/loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
limits_config:
  retention_period: ${days}d
  ingestion_rate_mb: 4
  ingestion_burst_size_mb: 8
  per_stream_rate_limit: 3MB
  per_stream_rate_limit_burst: 8MB
analytics:
  reporting_enabled: false
YML
mkdir -p /etc/alloy /etc/systemd/system/alloy.service.d
put /etc/alloy/config.alloy <<ALLOY && changed=1 || true
// Written by "hs recipe monitoring". Edits here are overwritten.
// The server journal arrives read-only at /var/log/host-journal.
loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["unit"]
    regex         = "session-[0-9]+\\\\.scope"
    target_label  = "unit"
    replacement   = "session"
  }
  rule {
    source_labels = ["__journal__transport"]
    regex         = "kernel"
    target_label  = "unit"
    replacement   = "kernel"
  }
  rule {
    source_labels = ["__journal__transport"]
    target_label  = "transport"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}
loki.source.journal "server" {
  path          = "/var/log/host-journal"
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  labels        = { job = "journal", host = "$name" }
  forward_to    = [loki.write.local.receiver]
}
loki.write "local" {
  endpoint {
    url = "http://127.0.0.1:3100/loki/api/v1/push"
  }
}
ALLOY
put /etc/default/alloy <<ENV && changed=1 || true
CONFIG_FILE="/etc/alloy/config.alloy"
CUSTOM_ARGS="--server.http.listen-addr=127.0.0.1:12345 --disable-reporting"
ENV
put /etc/systemd/system/alloy.service.d/hs-journal.conf <<UNIT && { changed=1; systemctl daemon-reload; } || true
[Service]
SupplementaryGroups=hs-journal
UNIT
systemctl reset-failed loki alloy 2>/dev/null || true
systemctl enable -q loki alloy
if [ $changed = 1 ]; then systemctl restart loki alloy; else systemctl start loki alloy; fi' "$days" "$(hostname)" "$jgid"
fi

low_ports
in_ct "Grafana: its source and the dashboards" '
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<YML
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
YML
cat > /etc/grafana/provisioning/dashboards/hs.yaml <<YML
apiVersion: 1
providers:
  - name: hs
    type: file
    allowUiUpdates: true
    options: { path: /var/lib/grafana/dashboards }
YML
install -m 644 /tmp/homeserver.json /var/lib/grafana/dashboards/homeserver.json
if [ "$2" = 1 ]; then
  cat > /etc/grafana/provisioning/datasources/loki.yaml <<YML
apiVersion: 1
datasources:
  - name: Loki
    uid: loki
    type: loki
    url: http://127.0.0.1:3100
    editable: false
YML
  install -m 644 /tmp/errors.json /var/lib/grafana/dashboards/errors.json
else
  rm -f /etc/grafana/provisioning/datasources/loki.yaml /var/lib/grafana/dashboards/errors.json
fi
# ready-made dashboards for the details; missing ones are fetched again on the next run
for d in "1860 node-exporter-full" "22604 smart-disks" "19727 incus"; do
  id=${d% *}; file=/var/lib/grafana/dashboards/${d#* }.json
  [ -s "$file" ] && continue
  if curl -fsSL -m 60 "https://grafana.com/api/dashboards/$id/revisions/latest/download" -o "$file.new"; then
    # they name their source through a placeholder; point it at ours
    sed -i -E "s/\\\$\{DS_[A-Z0-9_]+\}/prometheus/g" "$file.new" && mv "$file.new" "$file"
  else
    rm -f "$file.new"; echo "could not download the dashboard ${d#* }"
  fi
done
chown -R grafana:grafana /var/lib/grafana/dashboards

# everyone at home may look without logging in; changing needs the admin login
ini=/etc/grafana/grafana.ini
# our block is always the end of the file: drop the old one, write it new
sed -i "/^# hs recipe monitoring/,\$d" $ini
cat >> $ini <<INI
# hs recipe monitoring
[server]
http_port = $1
[auth.anonymous]
enabled = true
org_role = Viewer
[dashboards]
default_home_dashboard_path = /var/lib/grafana/dashboards/homeserver.json
[analytics]
reporting_enabled = false
check_for_updates = false
INI
systemctl enable -q grafana-server
systemctl restart grafana-server' "$PORT" "$logs"
if grep -q "could not download" <<<"$spin_out"; then warn "Some ready-made dashboards could not be downloaded; run the recipe again later."; fi

spin "Waiting for Grafana to answer" bash -c 'for _ in $(seq 1 60); do curl -fsS -m 3 -o /dev/null "$1/api/health" 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$(web)" ||
  fail "$(t 'Grafana does not answer at %s. Look at: incus exec %s -- journalctl -u grafana-server' "$(web)" "$ct")"

step "Admin login of Grafana"
mkdir -p "$state"
if [ "$(secret_state "$state/grafana-admin")" = locked ]; then
  # the password may exist in the closed vault: do not replace it, do not claim there is none
  vault_locked_note >&2; exit 1
fi
if [ -s "$state/grafana-admin" ]; then
  ok "$(t 'Kept as it is (password in %s/grafana-admin)' "$state")"
else
  # a fresh Grafana has the well-known login admin/admin: replace it right away
  pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
  secret_prepare grafana-admin "$state" || exit 1   # with a vault: created inside it, linked at the old path
  incus exec "$ct" -- grafana cli --homepath /usr/share/grafana admin reset-admin-password "$pw" >/dev/null </dev/null
  ( umask 077; printf 'user: admin\npassword: %s\n' "$pw" > "$state/grafana-admin" )
  ok "$(t 'Random admin password set, stored in %s/grafana-admin (root only)' "$state")"
fi

step "Check"
spin "One round of collecting" sleep 20
up=$(incus exec "$ct" -- curl -fsS -m 5 'http://127.0.0.1:9090/api/v1/query?query=up' </dev/null | jq -r '.data.result[] | "\(.metric.job)\t\(.value[1])"')
bad=0
for job in server disks incus; do
  if grep -qP "^$job\t1$" <<<"$up"; then ok "$(t '%s: numbers arrive' "$job")"
  else warn "$(t '%s: no numbers yet' "$job")"; bad=1; fi
done
if [ $bad -eq 1 ]; then
  note "Prometheus on the server cannot reach every source. The disks need up to five minutes for"
  note "their first numbers, and the Incus numbers are missing while the storage is locked. Details:"
  note "$(t 'incus exec %s -- curl -s 127.0.0.1:9090/api/v1/targets' "$ct")"
fi

if [ "$logs" = 1 ]; then
  step "Check the logs"
  spin "Waiting for Loki" incus exec "$ct" -- bash -c 'for _ in $(seq 1 40); do curl -fsS -m 3 http://127.0.0.1:3100/ready >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1' ||
    warn "$(t 'Loki is not ready yet. Look at: incus exec %s -- journalctl -u loki' "$ct")"
  n=0
  for _ in $(seq 1 12); do
    n=$(incus exec "$ct" -- curl -fsS -m 10 -G http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({job="journal"}[1h]))' </dev/null 2>/dev/null | jq -r '.data.result[0].value[1] // 0' 2>/dev/null || echo 0)
    [ "${n:-0}" != 0 ] && break
    sleep 5
  done
  if [ "${n:-0}" != 0 ]; then ok "The server's journal arrives in Loki"
  else
    warn "No log lines yet."
    note "$(t 'Look at: incus exec %s -- journalctl -u alloy   (can it read /var/log/host-journal as group %s?)' "$ct" "$jgid")"
  fi
fi

declare_service monitoring Grafana grafana never-public Monitoring "History: load, disks, containers"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say '  Home page "Homeserver": problems, disk temperatures and errors, pools, containers.')
$(say "Looking needs no login. To change dashboards, log in as admin:")
$(t '  sudo cat %s/grafana-admin' "$state")
$(docs_hint containers-and-apps)
DONE
