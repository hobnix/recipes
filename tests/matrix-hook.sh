#!/usr/bin/env bash
# The Matrix hook (recipes/matrix-hook/run.sh, hs-matrix-hook.py, scripts/recipes/files/matrix-card/): the recipe's
# syntax and dry run, the receiver against a fake Matrix server in text mode and in card mode, and a smoke
# render of every event the cards know. Needs python3 and curl (cards: Pillow); no root, no incus.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/recipes
export HS_LANG=en HS_PLAIN=1
R=$SCRIPTS/recipes
P=$PKGS/matrix-hook
# the receiver finds matrix-card beside itself, as in the container: put them side by side
mkdir -p "$WORK/deploy" && cp "$P/hs-matrix-hook.py" "$WORK/deploy/" && cp -r "$R/files/matrix-card" "$WORK/deploy/"
H=$WORK/deploy/hs-matrix-hook.py
STATE=$WORK/state; mkdir -p "$STATE"

echo "-- recipe"
check "matrix-hook.sh parses" bash -n "$P/run.sh"
check "matrix-hook.sh is executable" test -x "$P/run.sh"
check "matrix-hook.sh has a German one-liner" grep -q '^# recipe.de: ' "$P/run.sh"
check_out "dry run names the service" "hs-matrix-hook" env HS_STATE_DIR="$STATE" bash "$P/run.sh" --dry-run

have python3 && have curl || { skip "python3 and curl are needed for the receiver"; finish; exit 0; }
PY="python3 -X utf8"
HAVE_PIL=false; $PY -c 'import PIL' 2>/dev/null && HAVE_PIL=true

LOG=$WORK/matrix.log; : > "$LOG"
$PY "$(dirname "$0")/fake-matrix.py" "$WORK/mport" "$LOG" &
FAKE=$!
trap 'kill $FAKE $(cat "$WORK/hook.pids" 2>/dev/null) 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ -s "$WORK/mport" ] && break; sleep 0.1; done
MPORT=$(cat "$WORK/mport")

# start_hook <name> <extra JSON keys>: prints the port the receiver listens on
start_hook() {
  local n=$1 extra=${2:-}
  cat > "$WORK/$n.json" <<JSON
{"homeserver":"http://127.0.0.1:$MPORT","bot_user":"@hs-bot:test","bot_password":"bot-pass","owner":"@admin:test","secret":"s3cret","port":0,"bind":"127.0.0.1"$extra}
JSON
  HS_HOOK_CONFIG=$WORK/$n.json HS_HOOK_STATE=$WORK/$n.state $PY "$H" > /dev/null 2> "$WORK/$n.err" &   # not the $(...) pipe: it would wait for the receiver
  echo $! >> "$WORK/hook.pids"
  for _ in $(seq 1 100); do grep -q listening "$WORK/$n.err" 2>/dev/null && break; sleep 0.1; done
  sed -n 's/.*listening on [^ ]*:\([0-9]*\).*/\1/p' "$WORK/$n.err" | head -n1
}
post() {   # post <port> <path> <json>: prints the HTTP status
  curl -s -o /dev/null -w '%{http_code}' -m 60 -X POST -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$1$2"
}
last() { grep -v '"login"' "$LOG" | tail -n1; }   # the newest message, not a login of the chat loop
messages() { grep -c '"msgtype"' "$LOG" || true; }

echo "-- receiver, text mode"
HPORT=$(start_hook text ',"cards":false,"confirm_seconds":2')
P() { post "$HPORT" "$@"; }
check_out "healthz answers" '"ok": true' curl -s "http://127.0.0.1:$HPORT/healthz"
check_out "text mode says so" 'cards: off' cat "$WORK/text.err"
check_eq "wrong secret is refused" 403 "$(P /hook/nope/media '{}')"
check_eq "a room name with a slash is not a route" 404 "$(P /hook/s3cret/a/b '{}')"
check_eq "a bad room name is refused" 400 "$(P /hook/s3cret/Media '{}')"
check_eq "not JSON is refused" 400 "$(P /hook/s3cret/media 'garbage')"

radarr_grab='{"eventType":"Grab","movie":{"title":"Dune","year":2021},"release":{"quality":"WEBDL-2160p","size":13194139533,"indexer":"NZBgeek","releaseTitle":"Dune.2021.2160p"},"downloadClient":"SABnzbd"}'
check_eq "Radarr Grab is posted" 200 "$(P /hook/s3cret/media "$radarr_grab")"
check_out "the room is made once and the owner invited" '"createRoom": "Media", "invite": \["@admin:test"\]' grep createRoom "$LOG"
check_out "the media room is read-only for the owner (bot 100, owner 50)" '"createRoom": "Media".*"events_default": 100.*"@admin:test": 50' grep '"createRoom": "Media"' "$LOG"
check_out "the bot made its own room for commands, a direct chat" '"createRoom": "Homeserver bot", "invite": \["@admin:test"\], "direct": true' grep 'Homeserver bot' "$LOG"
check_out "the bot logged in as the local part" '"login": "hs-bot"' grep login "$LOG"
check_out "message names the service and the movie" '\*\*Radarr\*\* · Grabbed\\n\*\*Dune\*\* · 2021' last
check_out "quality, size, indexer, client on one line" 'Quality: WEBDL-2160p · Size: 12.3 GB · Indexer: NZBgeek · Client: SABnzbd' last
check_out "the release name is the code line" '`Dune.2021.2160p`' last
check_out "formatted as HTML for Matrix" '"format": "org.matrix.custom.html".*<strong>Radarr</strong>' last
check_out "a text message, not a notice (notices are silent in Element)" '"msgtype": "m.text"' last

sonarr_up='{"eventType":"Download","isUpgrade":true,"series":{"title":"Show_One","year":2020},"episodes":[{"seasonNumber":1,"episodeNumber":2,"title":"Pilot"}],"episodeFile":{"quality":"WEBDL-1080p","size":1500000000,"path":"/tv/x.mkv"},"deletedFiles":[{"quality":"HDTV-720p"}]}'
check_eq "Sonarr upgrade is posted" 200 "$(P /hook/s3cret/media "$sonarr_up")"
check_out "upgrade, escaped underscore, episode on the title line" 'Upgraded\\n\*\*Show\\\\_One\*\* · S01E02' last
check_out "from and to" 'From: HDTV-720p · To: WEBDL-1080p · Size: 1.4 GB' last
check_eq "only one Media room was made" 1 "$(grep -c '"createRoom": "Media"' "$LOG")"

pack='{"eventType":"Download","series":{"title":"Below"},"episodes":[{"seasonNumber":1,"episodeNumber":3,"title":"Sir John Franklin"}],"episodeFile":{"quality":"WEBDL-2160p","size":3758096384}}'
check_eq "one episode import is posted" 200 "$(P /hook/s3cret/media "$pack")"
check_out "one episode stays on the title line" 'Imported\\n\*\*Below\*\* · S01E03\\nEpisode: Sir John Franklin · Quality: WEBDL-2160p · Size: 3.5 GB' last

seerr='{"notification_type":"MEDIA_APPROVED","subject":"Arcane (2021)","media":{"media_type":"tv"},"request":{"requestedBy_username":"ann"},"extra":[{"name":"Requested Seasons","value":"2"}]}'
check_eq "Seerr approval is posted" 200 "$(P /hook/s3cret/media "$seerr")"
check_out "request approved with requester, season and target" 'Seerr\*\* · Request approved\\n\*\*Arcane\*\* · Season 2\\nRequested by: ann · Type: Series · Status: Sent to Sonarr' last

check_eq "Radarr rename is posted" 200 "$(P /hook/s3cret/media '{"eventType":"Rename","movie":{"title":"Past Lives","year":2023},"renamedMovieFiles":[{"previousRelativePath":"a/Past.Lives.mkv","relativePath":"Past Lives (2023).mkv"}]}')"
check_out "rename shows old and new" 'Renamed.*`Past.Lives.mkv` → `Past Lives \(2023\).mkv`' last
before=$(messages)
check_eq "an unknown event answers 200" 200 "$(P /hook/s3cret/media '{"eventType":"SomethingNew","movie":{"title":"X"}}')"
check_eq "Seerr request pending is not posted" 200 "$(P /hook/s3cret/media '{"notification_type":"MEDIA_PENDING","subject":"X"}')"
check_eq "nothing was sent for them" "$before" "$(messages)"

check_eq "health issue is posted" 200 "$(P /hook/s3cret/media '{"eventType":"Health","level":"Error","type":"IndexerStatusCheck","message":"Indexer unavailable","instanceName":"Radarr"}')"
check_out "health text" 'Health issue\\n\*\*Indexer unavailable\*\*\\nLevel: Error · Check: IndexerStatusCheck' last
check_eq "test button is posted" 200 "$(P /hook/s3cret/media '{"eventType":"Test","movie":{"title":"Test Title"}}')"
check_out "test text" 'Radarr\*\* · Test' last

check_eq "free text is posted as markdown" 200 "$(P /hook/s3cret/alerts '{"text":"**Backup** done\n- 3 files"}')"
check_out "a second room is made for another name" '"createRoom": "Alerts"' grep createRoom "$LOG"
check_out "HTML in a title is escaped" '&lt;b&gt;' bash -c "curl -s -o /dev/null -X POST -d '{\"text\":\"<b>x</b>\"}' http://127.0.0.1:$HPORT/hook/s3cret/media; tail -n1 $LOG"

curl -s -o /dev/null -X POST "http://127.0.0.1:$MPORT/_test/expire"
check_eq "an expired token logs in again" 200 "$(P /hook/s3cret/media "$radarr_grab")"
check "a second login happened (the receiver and the chat loop share the token)" test "$(grep -c '"login"' "$LOG")" -ge 2
check "the rooms are remembered across restarts" grep -q '"media"' "$WORK/text.state/rooms.json"
check "the secret is not written to the log" bash -c "! grep -q s3cret '$WORK/text.err'"


echo "-- chat commands"
RID=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['chat'])" "$WORK/text.state/rooms.json" 2>/dev/null || true)
check_eq "free text made the room chat" 200 "$(P /hook/s3cret/chat '{"text":"first message"}')"
RID=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['chat'])" "$WORK/text.state/rooms.json")
now_ms() { $PY -c 'import time;print(int(time.time()*1000))'; }
say() {   # say <text> [sender]: somebody types into the room
  curl -s -o /dev/null -X POST -d "{\"room\":\"$RID\",\"sender\":\"${2:-@admin:test}\",\"body\":\"$1\"}" "http://127.0.0.1:$MPORT/_test/say"
}
await() {   # await <regex>: the bot's answer shows up in the log (up to 10 s)
  for _ in $(seq 1 100); do grep -Eq -- "$1" "$LOG" && return 0; sleep 0.1; done; return 1
}
events() { curl -s "http://127.0.0.1:$MPORT/_test/events?room=$RID"; }
redacted_count() { events | $PY -c 'import json,sys;print(len(json.load(sys.stdin)["redacted"]))'; }
NOW=$(now_ms)
SEEDED=$(curl -s -X POST -d "{\"room\":\"$RID\",\"ts_list\":[$((NOW-20*86400000)),$((NOW-15*86400000)),$((NOW-8*86400000)),$((NOW-7200000)),$((NOW-3600000))]}" "http://127.0.0.1:$MPORT/_test/seed")
RECENT=$(echo "$SEEDED" | $PY -c 'import json,sys;i=json.load(sys.stdin)["ids"];print(i[3]+"|"+i[4])')
sleep 1   # the chat loop has its first answer (the backlog) by now

say help
check "help answers with the command list" await '"body": "\*\*Commands\*\*'
check_out "help lists clear and mute" 'clear \[<room>\] \[from <time>\] \[to <time>\]' grep -m1 '\*\*Commands' "$LOG"
before=$(grep -c 'Commands' "$LOG")
say help "@mallory:test"
sleep 1.5
check_eq "somebody else gets no answer" "$before" "$(grep -c 'Commands' "$LOG")"

say "clear banana"
check "an unreadable clear says so" await 'I did not understand `banana`'

say "clear to 7d"
check "clear asks first, with the count" await 'This deletes \*\*3\*\* messages'
check_eq "nothing was deleted before the yes" 0 "$(redacted_count)"
say yes
check "the yes deletes and reports" await 'Deleted \*\*3\*\* messages'
check_eq "3 old messages, the command, the question and the yes are redacted" 6 "$(redacted_count)"
recent_live() { events | $PY -c 'import json,sys;live=json.load(sys.stdin)["live"];sys.exit(0 if all(i in live for i in sys.argv[1].split("|")) else 1)' "$RECENT"; }
check "the recent messages are still there" recent_live

curl -s -o /dev/null -X POST -d '{"n":2}' "http://127.0.0.1:$MPORT/_test/ratelimit"
say "clear to 30m"
check "the second clear counts the two recent messages" await 'This deletes \*\*2\*\* messages'
say yes
check "a rate limit (429) is waited out" await 'Deleted \*\*2\*\* messages'

curl -s -o /dev/null -X POST -d "{\"room\":\"$RID\",\"ts_list\":[$((NOW-30*86400000))]}" "http://127.0.0.1:$MPORT/_test/seed"
say "clear to 7d"
check "a third clear asks again" await 'This deletes \*\*1\*\* messages'
sleep 3
say yes
check "a yes that comes too late deletes nothing" await 'took longer than 2 seconds'

say "clear to 90d"
check "an empty range says so" await 'Nothing to delete in `chat` from'

say "mute radarr 1h"
check "mute answers" await 'Muted \*\*Radarr\*\* until'
check_out "a muted service is dropped" '"muted": true' curl -s -X POST -H 'Content-Type: application/json' -d "$radarr_grab" "http://127.0.0.1:$HPORT/hook/s3cret/media"
check_out "the others still post" '"posted": true' curl -s -X POST -H 'Content-Type: application/json' -d "$sonarr_up" "http://127.0.0.1:$HPORT/hook/s3cret/media"
say status
check "status shows the mute" await 'Muted: \*\*Radarr\*\* until'
check_out "status shows when Sonarr last posted" 'Sonarr last posted: [0-9]' grep 'Cards: ' "$LOG"
say unmute
check "unmute answers" await 'Posting again'
check_out "Radarr posts again" '"posted": true' curl -s -X POST -H 'Content-Type: application/json' -d "$radarr_grab" "http://127.0.0.1:$HPORT/hook/s3cret/media"

before=$(messages)
say test
for _ in $(seq 1 100); do [ "$(messages)" -ge $((before + 3)) ] && break; sleep 0.1; done
check_eq "test posts one card each for Radarr, Sonarr, Seerr, Maintainerr and Downloadarr" $((before + 5)) "$(messages)"
check_out "the last test is Downloadarr's" 'Downloadarr[*][*] · Test' last

echo "-- the room with the bot"
CMD=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['_commands'])" "$WORK/text.state/rooms.json")
MEDIA=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['media'])" "$WORK/text.state/rooms.json")
say_in() { curl -s -o /dev/null -X POST -d "{\"room\":\"$1\",\"sender\":\"@admin:test\",\"body\":\"$2\"}" "http://127.0.0.1:$MPORT/_test/say"; }
redacted_in() { curl -s "http://127.0.0.1:$MPORT/_test/events?room=$1" | $PY -c 'import json,sys;print(len(json.load(sys.stdin)["redacted"]))'; }
say_in "$CMD" status
check "status in the bot room says the rooms are read-only" await '"room": "'"$CMD"'".*read-only for you'
say_in "$CMD" help
check "help is answered in the bot room too" await '"room": "'"$CMD"'".*\*\*Commands\*\*'
say_in "$CMD" "clear nosuchroom to 7d"
check "an unknown room name is not guessed" await 'I did not understand `nosuchroom`'
NOW=$(now_ms)
curl -s -o /dev/null -X POST -d "{\"room\":\"$MEDIA\",\"ts_list\":[$((NOW-30*86400000)),$((NOW-20*86400000))]}" "http://127.0.0.1:$MPORT/_test/seed"
say_in "$CMD" "clear media to 7d"
check "clear from the bot room names the target room" await 'This deletes \*\*2\*\* messages in `media`'
say_in "$CMD" yes
check "it reports from the bot room" await 'Deleted \*\*2\*\* messages in `media`'
check_eq "the two old messages of the media room are gone" 2 "$(redacted_in "$MEDIA")"
check_eq "the command, the question and the yes are removed where they were typed" 3 "$(redacted_in "$CMD")"
before=$(messages)
say_in "$CMD" "test media"
for _ in $(seq 1 100); do [ "$(messages)" -ge $((before + 3)) ] && break; sleep 0.1; done
check_eq "test in the bot room posts the cards to the media room" $((before + 5)) "$(messages)"

check_out "the parsing of times and arguments" '^[0-9]+ checks ok' $PY "$(dirname "$0")/matrix-chat-test.py" "$R/files/matrix-card"

echo "-- receiver, cards"
if ! $HAVE_PIL; then
  skip "Pillow (python3-pil) is needed for the cards"
else
  : > "$LOG"
  mkdir -p "$WORK/cards.state"; echo '{"media":"!legacy:test"}' > "$WORK/cards.state/rooms.json"   # a room from before it was read-only
  CPORT=$(start_hook cards ',"timezone":"Europe/Vienna","card_width":1350')
  C() { post "$CPORT" "$@"; }
  check_out "cards are on" 'cards: on' cat "$WORK/cards.err"
  check "an older room is made read-only at the start" await '"powerlevels": "!legacy:test".*"events_default": 100'
  check_out "the owner may moderate (50) and react" '"@admin:test": 50' grep powerlevels "$LOG"
  grab_poster='{"eventType":"Grab","movie":{"title":"Dune: Part Two","year":2024,"images":[{"coverType":"poster","remoteUrl":"http://127.0.0.1:'$MPORT'/poster.png"}]},"release":{"quality":"WEBDL-2160p","size":13194139533,"indexer":"NZBgeek","releaseTitle":"Dune.Part.Two.2024"},"downloadClient":"SABnzbd"}'
  check_eq "a card is posted" 200 "$(C /hook/s3cret/media "$grab_poster")"
  check_out "the poster was fetched" '"poster"' grep poster "$LOG"
  check_out "the card was uploaded as a PNG" '"png": true' grep upload "$LOG"
  check_out "the card is an image message, declared 1350x450 as configured" '"msgtype": "m.image".*"url": "mxc://test/media1".*"w": 1350, "h": 450' last
  check_out "the alt text has the title" '"body": "🎬 Radarr · Grabbed\\nDune: Part Two' last
  check_eq "the poster is cached for the next card" 200 "$(C /hook/s3cret/media "$grab_poster")"
  check_eq "one fetch only" 1 "$(grep -c '"poster"' "$LOG")"
  check_eq "a free text message stays text" 200 "$(C /hook/s3cret/media '{"text":"hello"}')"
  check_out "text message" '"msgtype": "m.text"' last

  echo "-- every card renders"
  check_out "all events draw 1800x600 PNGs" '^[0-9]+ cards ok' $PY "$(dirname "$0")/matrix-card-smoke.py" "$R/files/matrix-card" ${HS_CARD_SHEET:+"$HS_CARD_SHEET"}
fi

kill $FAKE $(cat "$WORK/hook.pids" 2>/dev/null) 2>/dev/null
finish
