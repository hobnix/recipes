#!/usr/bin/env bash
# The standard database dump for the backup: the descriptor (scripts/lib/backup-dump.sh), the program that runs inside
# the container (scripts/recipes/files/hs-dump) and the recipe helpers. No root, no incus, no databases: fakes stand in.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_LANG=en HS_PLAIN=1
D=$WORK/descr; DUMP=$WORK/dumps; BIN=$WORK/bin
mkdir -p "$D" "$BIN" "$DUMP"
. "$SCRIPTS/lib/backup-dump.sh"

echo "-- the descriptor"
dump_declare "$D/web" app "hs-dump sqlite app /srv/a.db"
dump_declare "$D/web" db "hs-dump postgres web web"
check_eq "two commands, in order" "hs-dump sqlite app /srv/a.db|hs-dump postgres web web" "$(dump_cmds "$D/web" | paste -sd'|')"
dump_declare "$D/web" app "hs-dump sqlite app /srv/b.db"
check_eq "declaring a name again replaces its command" "hs-dump postgres web web|hs-dump sqlite app /srv/b.db" "$(dump_cmds "$D/web" | paste -sd'|')"
printf '/usr/local/sbin/old-dump\n' > "$D/old"
check_eq "an old file with one bare line still works" "/usr/local/sbin/old-dump" "$(dump_cmds "$D/old")"
dump_remove "$D/web" db
check_eq "remove takes the command and its marker" "hs-dump sqlite app /srv/b.db" "$(dump_cmds "$D/web")"
dump_remove "$D/web" app
check "the file goes when the last command goes" test ! -e "$D/web"
check "an empty command is refused" bash -c ". $SCRIPTS/lib/backup-dump.sh; ! dump_declare $D/x n ''"

echo "-- hs-dump with fakes"
cat > "$BIN/sqlite3" <<'F'
#!/bin/sh
# sqlite3 <db> ".backup '<target>'"
t=${2#.backup \'}; t=${t%\'}
[ -z "${FAKE_SQLITE_FAIL:-}" ] || exit 1
cp "$1" "$t"
F
cat > "$BIN/runuser" <<'F'
#!/bin/sh
# runuser -u postgres -- pg_dump -Fc <db>
shift 3
[ -z "${FAKE_PG_FAIL:-}" ] || exit 1
echo "PGDMP $*"
F
cat > "$BIN/docker" <<'F'
#!/bin/sh
# docker compose exec -T <service> pg_dump -U <user> -Fc <db>
[ -z "${FAKE_PG_FAIL:-}" ] || exit 1
echo "PGDMP compose $*"
F
chmod +x "$BIN/sqlite3" "$BIN/runuser" "$BIN/docker"
HD() { env PATH="$BIN:$PATH" HS_DUMP_DIR="$DUMP" sh "$SCRIPTS/recipes/files/hs-dump" "$@"; }

HD postgres synapse synapse >/dev/null
check_out "postgres: the dump is in place" "PGDMP" cat "$DUMP/synapse/synapse.pgdump"
check "postgres: no temporary file is left" test ! -e "$DUMP/synapse/synapse.pgdump.tmp"
FAKE_PG_FAIL=1 HD postgres synapse synapse >/dev/null 2>&1 && fail "postgres: a failing pg_dump fails" || pass "postgres: a failing pg_dump fails"
check_out "postgres: a failed run keeps the previous dump" "PGDMP" cat "$DUMP/synapse/synapse.pgdump"
HD postgres-compose authentik "$WORK" postgresql authentik authentik >/dev/null
check_out "compose: the dump is in place" "PGDMP compose" cat "$DUMP/authentik/authentik.pgdump"
FAKE_PG_FAIL=1 HD postgres-compose authentik "$WORK" postgresql authentik authentik >/dev/null 2>&1 && fail "compose: a failing dump fails" || pass "compose: a failing dump fails"

mkdir -p "$WORK/app/sub" "$DUMP/arr"
echo one > "$WORK/app/radarr.db"; echo two > "$WORK/app/sub/sonarr.sqlite"; echo no > "$WORK/app/notes.txt"
HD sqlite-tree arr "$WORK/app" >/dev/null
check_out "tree: a database in the top folder" "one" cat "$DUMP/arr/radarr.db"
check_out "tree: a database in a subfolder, path flattened" "two" cat "$DUMP/arr/sub_sonarr.sqlite"
check "tree: other files are left alone" test ! -e "$DUMP/arr/notes.txt"
HD sqlite web "$WORK/app/radarr.db" "$WORK/app/missing.db" >/dev/null 2>&1
check_out "sqlite: a named file" "one" cat "$DUMP/web/radarr.db"
FAKE_SQLITE_FAIL=1 HD sqlite-tree arr "$WORK/app" >/dev/null 2>&1 && fail "tree: a failing sqlite3 fails" || pass "tree: a failing sqlite3 fails"
check_out "tree: a failed run keeps the previous dump" "one" cat "$DUMP/arr/radarr.db"
check "a bad name is refused" bash -c "! env PATH=$BIN:\$PATH HS_DUMP_DIR=$DUMP sh $SCRIPTS/recipes/files/hs-dump postgres ../x db"
check "no arguments print the usage and fail" bash -c "! sh $SCRIPTS/recipes/files/hs-dump"

echo "-- recipe helpers"
cat > "$WORK/driver.sh" <<DRV
set -euo pipefail
scripts=$SCRIPTS
state=$WORK/state
ct=probe
. $SCRIPTS/recipes/_lib.sh
. $SCRIPTS/recipes/_media.sh
"\$@"
DRV
cat > "$BIN/incus" <<'F'
#!/bin/sh
case "$1" in info) exit 1 ;; esac
echo "$*" >> "${FAKE_LOG:-/dev/null}"
exit 0
F
chmod +x "$BIN/incus"
export PATH="$BIN:$PATH" HS_STATE_DIR=$WORK/state
mkdir -p "$WORK/state"
h() { FAKE_LOG=$WORK/incus.log bash "$WORK/driver.sh" "$@"; }
h backup_with_dump pg "hs-dump postgres x x" >/dev/null 2>&1 || true
h backup_with_dump pg "hs-dump postgres x y" >/dev/null 2>&1 || true
check_eq "a recipe run twice leaves one command" "hs-dump postgres x y" "$(dump_cmds "$WORK/state/backup-dump/probe")"
h media_backup "/usr/local/sbin/hs-dump sqlite-tree probe /opt/probe" >/dev/null 2>&1 || true
check_eq "media_backup replaces the whole descriptor" "/usr/local/sbin/hs-dump sqlite-tree probe /opt/probe" "$(dump_cmds "$WORK/state/backup-dump/probe")"
h install_dump_tool >/dev/null 2>&1 || true
check_out "the tool is pushed into the container" "file push .*hs-dump probe/usr/local/sbin/hs-dump" cat "$WORK/incus.log"

echo "-- the recipes use it"
for r in immich synapse authentik arr; do
  check "$r installs the dump tool" grep -q 'install_dump_tool' "$PKGS/$r/run.sh"
  check "$r declares its dump through the standard" grep -Eq 'backup_with_dump|media_backup' "$PKGS/$r/run.sh"
  check "$r parses" bash -n "$PKGS/$r/run.sh"
done
check "hs-dump parses" sh -n "$SCRIPTS/recipes/files/hs-dump"

finish
