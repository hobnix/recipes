#!/usr/bin/env bash
# recipe: Catalyst panel: game server panel (TypeScript panel, Rust node agent, containerd), the web page
# recipe.de: Catalyst-Panel: Spieleserver-Panel (TypeScript-Panel, Rust-Agent auf dem Node, containerd), die Webseite
# kind: generic
# needs: docker
# uses: -
set -euo pipefail

# What it does: creates the container "catalyst-panel" with Docker inside and runs
# Catalyst's own installer in it (github.com/catalystctl/catalyst, docs.catalystctl.com).
# The installer makes the secrets and writes the Docker Compose stack (panel,
# PostgreSQL, Redis) into /opt/catalyst/catalyst-docker, the recipe starts it.
# Everything lives in the container, so a backup of the container
# (hs backup ct catalyst-panel on) holds the whole setup.
# The games run on a node: hs recipe catalyst-node (a second container).
# The panel is an admin page: it never gets a Zoraxy rule.
# Experimental software ("early testing" says its README): a test setup.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# RECIPE_SKIP_PULL=1 (no download of the images and no start: only the installer runs).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-catalyst-panel}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Docker inside and run Catalyst's installer (it makes the secrets and the Compose stack: panel, database, Redis)"
  say "  start the stack and wait for the web page"
  exit 0
fi

port_setting "Catalyst" 80
ensure_container "$ct" 4096 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
install_docker

step "Catalyst"
# the installer asks for the address of the panel: it is the one the nodes and your browser use
in_ct "Running Catalyst's installer" '
  mkdir -p /opt/catalyst && cd /opt/catalyst
  if [ ! -s catalyst-docker/.env ]; then
    curl -fsSL -m 60 -o install.sh https://github.com/catalystctl/catalyst/releases/latest/download/install.sh
    url="http://$1"; [ "$2" = 80 ] || url="http://$1:$2"
    bash install.sh -y --set "PUBLIC_URL=$url" --set "FRONTEND_PORT=0.0.0.0:$2"
  fi
  # the compose default for this setting (keep) is not a value the backend accepts (block or allow): it would not start
  grep -q "^SUSPENSION_DELETE_POLICY=" catalyst-docker/.env || echo "SUSPENSION_DELETE_POLICY=block" >> catalyst-docker/.env
  cd catalyst-docker && docker compose config -q' "$ip" "$PORT"

start='cd /opt/catalyst/catalyst-docker && docker compose up -d --remove-orphans'
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Catalyst not started"
else
  in_ct "Downloading Catalyst" 'cd /opt/catalyst/catalyst-docker && docker compose pull -q'
  in_ct "Starting Catalyst" "$start"
  wait_page Catalyst 'docker compose -f /opt/catalyst/catalyst-docker/docker-compose.yml logs --tail 50' --tries 150
  ok "Catalyst is running"
fi

recipe_facts web
declare_service catalyst-panel Catalyst mdi-gamepad-variant private-ok Games "Game server panel"
box <<DONE
$(say "Catalyst is still experimental: use it for tests, not for worlds you cannot lose.")
$(t '  1. Open %s and finish the setup wizard: the first account you make is the administrator.' "$(web)")
$(say "  2. Admin -> Nodes -> Register Node: type the address of the node (hs recipe catalyst-node makes it).")
$(say "     The last step shows an install command with a token: copy it, it is shown once.")
$(say "  3. On this server run:  sudo hs recipe catalyst-node  and paste the command when it asks.")
$(say "No Zoraxy rule for the panel: it is an admin page.")
$(docs_hint containers-and-apps)
DONE
