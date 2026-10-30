#!/usr/bin/env bash
# The duplicate cleanup of the radarr recipe (recipes/radarr/hs-arr-dedupe.py), the shared sender (files/hs-media-notify.py)
# and the cards of the new services. Fake ffprobe (height from the file name), no root, no incus, no network.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_LANG=en HS_PLAIN=1
P() { cygpath -m "$1" 2>/dev/null || echo "$1"; }   # Windows Python needs C:/ paths (Git bash)
F=$(P "$SCRIPTS/recipes/files")            # shared: hs-media-notify.py, matrix-card
A=$(P "$PKGS/radarr")              # the radarr recipe: hs-arr-dedupe.py
have python3 || { skip "python3 is needed"; finish; exit 0; }
PY="python3 -X utf8"
W=$(P "$WORK"); MEDIA=$W/movies; STATE=$W/dstate; LOG=$W/notify.log; mkdir -p "$MEDIA" "$WORK/bin"
export HS_DEDUPE_NO_RADARR=1 HS_MEDIA_NOTIFY_LOG=$LOG HS_DEDUPE_NOTIFY="$PY $F/hs-media-notify.py"

cat > "$WORK/ffprobe.py" <<'FAKE'
import sys
f = sys.argv[-1]
print(2160 if "2160" in f else 1080 if "1080" in f else 720 if "720" in f else "")
FAKE
export HS_DEDUPE_FFPROBE="$PY $W/ffprobe.py"
mk() { mkdir -p "$WORK/movies/$1"; truncate -s "${3:-120M}" "$WORK/movies/$1/$2"; }
mk "Heat (1995)" "Heat.2160p.mkv" 150M;   mk "Heat (1995)" "Heat.1080p.mkv"
mk "Alien (1979)" "Alien.1080p.mkv";      mk "Alien (1979)" "Alien.1080p.alt.mkv"       # equal: never touched
mk "Up (2009)" "Up.1080p.mkv"                                                          # one file
mk "Ronin (1998)" "Ronin.2160p.mkv";      mk "Ronin (1998)" "Ronin.720p.mkv"; touch "$WORK/movies/Ronin (1998)/.keep-both"
mk "Dune (2021)" "Dune.2160p.mkv";        mk "Dune (2021)" "Dune.1080p.mkv" 10M       # small: a sample, not a copy
mk "Odd (2000)" "Odd.2160p.mkv";          mk "Odd (2000)" "Odd.broken.mkv"             # unreadable: no decision
D="$PY $A/hs-arr-dedupe.py --media $MEDIA --state $STATE"

echo "-- dry run"
check_out "lists the 1080p copy of Heat" "Heat.*keep 2160p \(4K\).*drop 1080p" env HS_DEDUPE_NOW=2026-10-10 $D --dry-run
out=$(HS_DEDUPE_NOW=2026-10-10 $D --dry-run 2>&1)
check_eq "only Heat is a candidate" 1 "$(grep -c keep <<<"$out")"
check "dry run sends and saves nothing" test ! -e "$WORK/notify.log" -a ! -e "$WORK/dstate/pending.json"

echo "-- announce, wait, delete"
HS_DEDUPE_NOW=2026-10-10 $D >/dev/null
check "first run announces once" test "$(grep -c '"event": "planned"' "$WORK/notify.log")" = 1
check_out "the announcement names kept and deleted" '"Keep", "2160p \(4K\)".*"Delete", "1080p"' cat "$WORK/notify.log"
check "nothing deleted yet" test -e "$WORK/movies/Heat (1995)/Heat.1080p.mkv"
HS_DEDUPE_NOW=2026-10-20 $D >/dev/null
check "ten days later: still there, not announced twice" test "$(grep -c '"event": "planned"' "$WORK/notify.log")" = 1 -a -e "$WORK/movies/Heat (1995)/Heat.1080p.mkv"
HS_DEDUPE_NOW=2026-10-24 $D >/dev/null
check "after 14 days the 1080p file is gone" test ! -e "$WORK/movies/Heat (1995)/Heat.1080p.mkv"
check "the 4K file stays" test -e "$WORK/movies/Heat (1995)/Heat.2160p.mkv"
check "a 'deleted' message was sent" grep -q '"event": "deleted"' "$WORK/notify.log"
check "the vetoed film is untouched" test -e "$WORK/movies/Ronin (1998)/Ronin.720p.mkv"
check "equal resolutions are untouched" test -e "$WORK/movies/Alien (1979)/Alien.1080p.alt.mkv"
check "the unreadable file is untouched" test -e "$WORK/movies/Odd (2000)/Odd.broken.mkv"
check "every message is for Maintainerr" test "$(grep -vc '"service": "maintainerr"' "$WORK/notify.log")" = 0

echo "-- sender"
: > "$WORK/notify.log"
$PY $F/hs-media-notify.py Complete x 2>/dev/null; $PY $F/hs-media-notify.py complete "Job finished" "Some.Release.2160p" >/dev/null
$PY $F/hs-media-notify.py startup "Started" "" >/dev/null
check_eq "SABnzbd's script call becomes one finished message" 1 "$(wc -l < "$WORK/notify.log" | tr -d ' ')"
check_out "it is for the sabnzbd service, title cleaned, release name in the footer" '"event": "finished", "title": "Some Release".*"footer": "Some.Release.2160p"' cat "$WORK/notify.log"
cat > "$WORK/conf.json" <<'J'
{"ntfy": "http://127.0.0.1:9/topic", "hook": "http://127.0.0.1:9/hook/x/media"}
J
check "an unreachable ntfy and hook never fail the caller" env -u HS_MEDIA_NOTIFY_LOG HS_MEDIA_NOTIFY_CONF="$WORK/conf.json" $PY $F/hs-media-notify.py send --service maintainerr --event test --title T

echo "-- release names and the lookup"
check_out "a release name becomes title and year" "'Mad Max 2 Der Vollstrecker', '1981'"   $PY -c "import importlib.util as u; sp = u.spec_from_file_location('n', r'$F/hs-media-notify.py'); n = u.module_from_spec(sp); sp.loader.exec_module(n); print(n.parse_release('Mad.Max.2.Der.Vollstrecker.1981.German.DL.2160p.UHD.x265-GRP.nzb'))"
check_out "an episode is recognised" "'The Last of Us', '', 'S02E03', True"   $PY -c "import importlib.util as u; sp = u.spec_from_file_location('n', r'$F/hs-media-notify.py'); n = u.module_from_spec(sp); sp.loader.exec_module(n); print(n.parse_release('The.Last.of.Us.S02E03.German.DL.1080p.WEB.h264-WAYNE'))"
cat > "$WORK/lookup.py" <<'PYL'
import http.server, json, sys, threading, importlib.util as u
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        ok = "Mad%20Max%202%201981" in self.path     # only the shorter term finds it
        body = json.dumps([{"title": "Mad Max 2: The Road Warrior", "originalTitle": "Mad Max 2", "year": 1981, "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/x.jpg"}]}] if ok else []).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sp = u.spec_from_file_location("n", sys.argv[1]); n = u.module_from_spec(sp); sp.loader.exec_module(n)
conf = {"radarr": {"url": "http://127.0.0.1:%d" % srv.server_port, "key": "k"}}
print(n.lookup(conf, "Mad Max 2 Der Vollstrecker", "1981", False))
print(n.lookup({}, "Mad Max 2", "1981", False))
PYL
out=$($PY "$WORK/lookup.py" "$F/hs-media-notify.py")
check_out "the lookup tries fewer words and returns title, year, w342 poster" "Mad Max 2: The Road Warrior', '1981', 'https://image.tmdb.org/t/p/w342/x.jpg'" echo "$out"
check_out "without Radarr there is no lookup" "^None$" echo "$out"

echo "-- cards"
check_out "the Maintainerr payload is a card spec named 'Maintainerr (Script)'" "Maintainerr \(Script\)" \
  $PY -c "import sys; sys.path.insert(0, r'$F/matrix-card'); import specs; print(specs.spec_text(specs.spec_for({'hsService':'maintainerr','event':'Duplicate found','event_icon':'warning','title':'Heat','fields':[['Keep','4K']]})))"
check_out "an unknown service is not posted" "None" \
  $PY -c "import sys; sys.path.insert(0, r'$F/matrix-card'); import specs; print(specs.spec_for({'hsService':'nope'}))"
check_out "the bot accepts Downloadarr for the sabnzbd key" "'sabnzbd'"   $PY -c "import sys; sys.path.insert(0, r'$F/matrix-card'); import bot; print(bot.parse_mute('downloadarr 2h')[0])"
if $PY -c 'import PIL' 2>/dev/null; then
  check "both services render a PNG" $PY -c "
import sys; sys.path.insert(0, r'$F/matrix-card'); import specs, card
for s in ('maintainerr', 'sabnzbd'):
    png = card.render(specs.spec_for({'hsService': s, 'event': 'Test', 'event_icon': 'check-circle', 'title': 'Test message'}))
    assert png[:4] == b'\x89PNG'"
else skip "Pillow is needed to draw the cards"; fi

echo "-- recipes"
check "hs-arr-dedupe.py parses" $PY -c "import ast,sys; ast.parse(open(r'$A/hs-arr-dedupe.py').read())"
check "hs-media-notify.py parses" $PY -c "import ast,sys; ast.parse(open(r'$F/hs-media-notify.py').read())"
finish
