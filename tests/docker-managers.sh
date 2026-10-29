#!/usr/bin/env bash
# The docker capability (capabilities/docker/NOTES.md, docs/PLAN-modular-core.md step 4e): every manager variant in scripts/providers/docker/
# defines what packages/docker/run.sh needs, publishes the recipe's port and never the Docker socket without a volume line, and the recipe
# knows exactly these variants. The variants are sourced in a subshell each; no incus, no docker, no root.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
D=$SCRIPTS/providers/docker
say() { echo "$*"; }   # what manager_box calls (ui.sh's say in the recipe)

echo "-- every variant defines the same things"
variants=$(cd "$D" && ls *.sh | sed 's/\.sh$//' | tr '\n' ' ' | sed 's/ $//')
check_eq "the variants are arcane and portainer" "arcane portainer" "$variants"
for v in $variants; do
  out=$(bash -c '
    say() { echo "$*"; }
    . "$1"
    for f in manager_prepare manager_compose manager_stop manager_box; do [ "$(type -t $f)" = function ] || echo "no function $f"; done
    for v in manager_title manager_icon manager_desc manager_default_port manager_dir manager_log_hint; do [ -n "${!v:-}" ] || echo "no $v"; done
    case "$manager_dir" in /opt/*) ;; *) echo "manager_dir is not under /opt" ;; esac
  ' _ "$D/$v.sh")
  check_eq "$v: functions and variables" "" "$out"
done

echo "-- the compose files"
arcane=$(bash -c '. "$1"; manager_compose 8123 http://10.0.0.5:8123' _ "$D/arcane.sh")
portainer=$(bash -c '. "$1"; manager_compose 8123 http://10.0.0.5:8123' _ "$D/portainer.sh")
check "arcane publishes the recipe's port on its own (3552)" grep -q '"8123:3552"' <<<"$arcane"
check "arcane gets the url" grep -q 'APP_URL=http://10.0.0.5:8123' <<<"$arcane"
check "portainer publishes the recipe's port on its HTTP port (9000)" grep -q '"8123:9000"' <<<"$portainer"
check "and serves HTTP at all: --http-enabled (without it Portainer has HTTPS only)" grep -q 'command: --http-enabled' <<<"$portainer"
check "portainer keeps its data in a volume" grep -q 'portainer-data:/data' <<<"$portainer"
for v in arcane portainer; do
  c=$(bash -c '. "$1"; manager_compose 80 http://x' _ "$D/$v.sh")
  check "$v: a volume for its data is declared" grep -q '^volumes:' <<<"$c"
  check "$v: projects are reachable in /opt/projects" grep -q '/opt/projects' <<<"$c"
  check "$v: stopping keeps the volume (down without -v)" bash -c '. "$1"; ! manager_stop | grep -q -- " -v"' _ "$D/$v.sh"
done

echo "-- the arcane keys: made once, carried over from an older install, never new ones over stored data"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
# a stand-in: `docker volume ls -q` lists what DOCKER_VOLUMES says
[ "$1 $2" = "volume ls" ] && printf '%s\n' ${DOCKER_VOLUMES:-}
exit 0
EOF
chmod +x "$WORK/bin/docker"
prep() {   # prep <dir>: the prepare script of arcane in that directory (as inside the container: bash, set -euo pipefail)
  ARCANE_DIR=$1 PROJECTS_DIR=$1/projects PATH="$WORK/bin:$PATH" bash -c "set -euo pipefail; $(bash -c '. "$1"; manager_prepare' _ "$D/arcane.sh")" 2>&1
}
d=$WORK/a1; mkdir -p "$d"; prep "$d" >/dev/null
check_eq "a fresh install gets two new keys (64 hex characters each)" "2" "$(grep -cE '^(ENCRYPTION_KEY|JWT_SECRET)=[0-9a-f]{64}$' "$d/.env")"
cp "$d/.env" "$d/.env.first"; prep "$d" >/dev/null
check "and a second run leaves the .env alone" cmp -s "$d/.env" "$d/.env.first"

d=$WORK/a2; mkdir -p "$d"
printf 'services:\n  arcane:\n    image: x\n    environment:\n      - ENCRYPTION_KEY=oldkey1111\n      - JWT_SECRET=oldjwt2222\n      - APP_URL=http://x\n' > "$d/docker-compose.yml"
DOCKER_VOLUMES="arcane_arcane-data" prep "$d" >/dev/null
check_eq "the keys of an older compose file (list form) are carried over" "ENCRYPTION_KEY=oldkey1111 JWT_SECRET=oldjwt2222" "$(tr '\n' ' ' < "$d/.env" | sed 's/ $//')"
check "and that compose file is kept once (it is not the recipe's)" test -e "$d/docker-compose.yml.before-recipe"

d=$WORK/a8; mkdir -p "$d"
printf 'services:\n  arcane:\n    image: x\n    environment:\n      - APP_URL=http://x\n      - ENCRYPTION_KEY=onlykey3333\n' > "$d/docker-compose.yml"
DOCKER_VOLUMES="arcane_arcane-data" prep "$d" >/dev/null
check_eq "an older install with only an ENCRYPTION_KEY keeps it" "ENCRYPTION_KEY=onlykey3333" "$(grep '^ENCRYPTION_KEY=' "$d/.env")"
check_eq "and gets a new JWT_SECRET (it only signs logins)" "1" "$(grep -cE '^JWT_SECRET=[0-9a-f]{64}$' "$d/.env")"

d=$WORK/a3; mkdir -p "$d"
printf 'services:\n  arcane:\n    environment:\n      ENCRYPTION_KEY: "mapkey"\n      JWT_SECRET: mapjwt\n' > "$d/docker-compose.yml"
prep "$d" >/dev/null
check_eq "the map form, quoted or not, too" "ENCRYPTION_KEY=mapkey JWT_SECRET=mapjwt" "$(tr '\n' ' ' < "$d/.env" | sed 's/ $//')"

d=$WORK/a4; mkdir -p "$d"
printf 'services:\n  arcane:\n    environment:\n      - ENCRYPTION_KEY=${ENCRYPTION_KEY}\n      - JWT_SECRET=${JWT_SECRET}\n' > "$d/docker-compose.yml"
out=$(DOCKER_VOLUMES="arcane_arcane-data" prep "$d" || true)
check_out "placeholders are no keys: with stored data it refuses, and says why" "lock you out" echo "$out"
check "and writes no .env" test ! -e "$d/.env"
check_eq "and exits 1" "1" "$(DOCKER_VOLUMES=arcane_arcane-data prep "$d" >/dev/null; echo $?)"
d=$WORK/a5; mkdir -p "$d"; printf 'services: {}\n' > "$d/docker-compose.yml"
prep "$d" >/dev/null
check "without keys and without stored data it is a fresh install: new keys" test -s "$d/.env"

d=$WORK/a6; mkdir -p "$d"; printf 'ENCRYPTION_KEY=mine\nJWT_SECRET=mine2\n' > "$d/.env"
printf 'services:\n  arcane:\n    environment:\n      - ENCRYPTION_KEY=other\n      - JWT_SECRET=other2\n' > "$d/docker-compose.yml"
prep "$d" >/dev/null
check_eq "an existing .env wins: it is never replaced" "ENCRYPTION_KEY=mine JWT_SECRET=mine2" "$(tr '\n' ' ' < "$d/.env" | sed 's/ $//')"

d=$WORK/a7; mkdir -p "$d"; printf '# Written by "hs recipe docker". Run it again after changes; edits here are overwritten.\nservices: {}\n' > "$d/docker-compose.yml"
prep "$d" >/dev/null
check "a compose file the recipe wrote is not kept (nothing of an older install in it)" test ! -e "$d/docker-compose.yml.before-recipe"

echo "-- the arcane keys are made once (the script)"
check "the .env is only written when it is empty" bash -c '. "$1"; manager_prepare | grep -q "if \[ ! -s .env \]"' _ "$D/arcane.sh"

echo "-- the recipe"
R=$PKGS/docker/run.sh
check "it asks MANAGER with exactly these choices" grep -q "arcane|portainer|none" "$R"
check "installs from before the question count as arcane" grep -q 'setting MANAGER .* arcane arcane ' "$R"
check "it loops over the variants to stop the other one" grep -q 'variants="arcane portainer"' "$R"
check "and the manifest lists the same variants" grep -q 'variants = \["arcane", "portainer"\]' "$ROOT/capabilities/docker/capability.toml"
check "the service is declared never-public" grep -q 'declare_service docker .* never-public Administration' "$R"

finish
