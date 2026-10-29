#!/usr/bin/env bash
# recipe: Docker: run your own Docker apps (compose files), with Arcane or Portainer as the web page that manages them
# recipe.de: Docker: eigene Docker-Anwendungen (Compose-Dateien) betreiben, mit Arcane oder Portainer als Verwaltungsseite
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "docker" with Docker inside and runs a web page to manage Docker, the MANAGER you pick:
#   arcane     containers, images, and "projects" (docker-compose files, kept in /opt/projects) (default; installs from before the question)
#   portainer  Portainer CE, containers, images and stacks
#   none       Docker only, no web page
# Each is a variant file in scripts/providers/docker/ (capabilities/docker/NOTES.md). The choice is remembered per container
# ($state/recipe-<name>.conf; `--ask` asks again). Switching stops the old manager's containers and keeps its volume and compose file.
#   port 80   the manager's web page, for the home network only (it controls Docker: an admin page, never a Zoraxy rule)
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-docker}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 4096 MB RAM limit) unless it exists, with a fixed address (.20 to .29) if UniFi is connected (hs net setup)" "$ct")"
  say "  install Docker inside and start the manager you pick (Arcane in /opt/arcane, or Portainer in /opt/portainer, or none) on port 80; projects live in /opt/projects"
  exit 0
fi

# which web page manages Docker here: the question comes first, the port is asked for the one picked
setting MANAGER "$(t 'Web page to manage Docker: arcane, portainer or none')" arcane arcane 'arcane|portainer|none'
variants="arcane portainer"
if [ "$MANAGER" = none ]; then
  PORT=""
else
  # shellcheck source=/dev/null
  . "$scripts/providers/docker/$MANAGER.sh"
  port_setting "$manager_title" "$manager_default_port"
fi
ensure_container "$ct" 4096 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
install_docker

# a manager that was set up before and is not the one picked goes: its containers stop, its volume and compose file stay (switching back works)
for v in $variants; do
  [ "$v" != "$MANAGER" ] || continue
  (
    # shellcheck source=/dev/null
    . "$scripts/providers/docker/$v.sh"
    if incus exec "$ct" -- test -f "$manager_dir/docker-compose.yml" </dev/null 2>/dev/null; then
      step "$(t 'Replacing %s' "$manager_title")"
      in_ct "$(t 'Stopping %s (its data and compose file stay in %s)' "$manager_title" "$manager_dir")" "$(manager_stop)"
    fi
  )
done

if [ "$MANAGER" != none ]; then
  step "$manager_title"
  in_ct "$(t 'Preparing %s' "$manager_dir")" "$(manager_prepare)"
  manager_compose "$PORT" "$(web)" | incus exec "$ct" -- tee "$manager_dir/docker-compose.yml" >/dev/null
  ok "$(t 'Wrote %s/docker-compose.yml' "$manager_dir")"
  in_ct "$(t 'Downloading %s' "$manager_title")" "cd $manager_dir && docker compose pull -q"
  in_ct "$(t 'Starting %s' "$manager_title")" "cd $manager_dir && docker compose up -d --remove-orphans"
  wait_page "$manager_title" "$manager_log_hint" --plain --tries 60
  recipe_facts web
  declare_service docker "$manager_title" "$manager_icon" never-public Administration "$manager_desc"
else
  recipe_facts
  note "$(t 'No web page: use docker compose in /opt/projects inside the container (incus exec %s -- ...).' "$ct")"
fi

box <<DONE
$(if [ "$MANAGER" = none ]; then say "Docker is ready, without a web page. Projects go in /opt/projects."; else manager_box; fi)
$(docs_hint containers-and-apps)
DONE
