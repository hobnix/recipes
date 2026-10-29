#!/usr/bin/env bash
# Prometheus runs on the host, Grafana in the container reaches it through an Incus proxy device.
# Static checks of configuration.nix / machine.toml.example / the recipe, plus the recipe's --dry-run.
# No root, no incus, no nix needed.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_LANG=en HS_PLAIN=1
R=$PKGS/monitoring/run.sh
CONF=$ROOT/capabilities/metrics/module.nix   # moved out of configuration.nix; loaded while the capability `metrics` is on
EX=$ROOT/machine.toml.example

echo "-- host service (capabilities/metrics/module.nix)"
check "Prometheus is enabled" grep -q 'services.prometheus = {' "$CONF"
check "listens on 127.0.0.1 only" grep -q 'listenAddress = "127.0.0.1";' "$CONF"
check "retention by time" grep -q 'retentionTime = "${toString metricsDays}d"' "$CONF"
check "retention by size" grep -q 'retention.size=${toString metricsMaxGB}GB' "$CONF"
check "defaults 30 days / 5 GB" grep -Eq '^ *metricsDays = 30;' "$ROOT/config/defaults.nix"
check "default size cap" grep -Eq '^ *metricsMaxGB = 5;' "$ROOT/config/defaults.nix"
check "no firewall rule for 9090" bash -c "! grep -E 'dport.*9090' '$CONF'"
# the service must not wait for storage: no unit dependencies on it, no lock-marker condition
block=$(awk '/listenAddress = /,/^  };/' "$CONF")   # Prometheus itself, not the exporters beside it
check_eq "no unit dependency or lock-marker condition in the Prometheus block" "0" "$(grep -ciE "after|requires|wants|bindsTo|storage-locked|ConditionPath|systemd" <<<"$block")"
for j in server disks incus; do check "scrape job $j" grep -q "job_name = \"$j\"" <<<"$block"; done

echo "-- machine.toml.example"
check "metricsDays paragraph" grep -qE '^# metricsDays = 30$' "$EX"
check "metricsMaxGB paragraph" grep -qE '^# metricsMaxGB = 5$' "$EX"

echo "-- recipe"
check "syntax" bash -n "$R"
check "no Prometheus package in the container" bash -c "! grep -E 'install.*prometheus( |\\\\\"|\$)' '$R' | grep -v '^#'"
check "proxy device bound to the instance" grep -q 'proxy listen=tcp:127.0.0.1:9090 connect=tcp:127.0.0.1:9090 bind=instance' "$R"
check "old container Prometheus is disabled, not removed" grep -q 'systemctl disable --now prometheus' "$R"
check "Grafana still points at 127.0.0.1:9090" grep -q 'url: http://127.0.0.1:9090' "$R"
check "migration comes before the proxy device" bash -c "[ \$(grep -n 'disable --now prometheus' '$R' | head -1 | cut -d: -f1) -lt \$(grep -n 'device add' '$R' | head -1 | cut -d: -f1) ]"
check_out "dry run names the proxy device" "proxy device" bash "$R" --dry-run
check_out "dry run names the host Prometheus" "run Prometheus itself" bash "$R" --dry-run
check_out "dry run in German" "Proxy-Ger" env HS_LANG=de bash "$R" --dry-run

finish
