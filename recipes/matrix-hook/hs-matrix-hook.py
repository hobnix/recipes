#!/usr/bin/env python3
"""Webhook receiver that posts to a Matrix room (hs recipe matrix-hook).

Radarr, Sonarr and Seerr send a webhook (JSON) to  POST /hook/<secret>/<room>;  this program turns
the event into a notification card (an image, matrix-card/card.py, needs Pillow) or, when no card
can be made, a short markdown message, and sends it as the bot user to the Matrix room <room>
(made on first use, the owner is invited). Everything but the card runs on the standard library.
The owner types commands in a room of their own with the bot ("Homeserver bot", made at start, the owner is invited);
the media rooms are read-only for the owner (help, clear, status, test, mute: matrix-card/bot.py).

    POST /hook/<secret>/<room>   Radarr / Sonarr / Seerr payloads, or {"text": "markdown"} for anything else
    GET  /healthz                "ok"

Config (JSON, HS_HOOK_CONFIG, default /etc/hs-matrix-hook.json): homeserver, bot_user, bot_password,
owner, secret, port, bind; optional read_only (false = the owner may write in the rooms too), timezone (the time on the cards) and cards (false = text only).
optional confirm_seconds (how long `clear` waits for `yes`, default 60) and card_width (the width a card is declared with, default 900;
1350 shows it 1.5 times as large in Element, the image itself is always 1800x600).
State (HS_HOOK_STATE): rooms.json (room name -> room id), posters/ (the posters fetched for cards), mutes.json.
Events that matrix-card/specs.py does not know are answered with 200 and not posted.
"""
import hashlib
import hmac
import html
import json
import os
import random
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
for _dir in (os.path.join(HERE, "matrix-card"), HERE):
    if os.path.isdir(_dir) and _dir not in sys.path:
        sys.path.insert(0, _dir)
import bot  # noqa: E402  (the chat commands of the owner)
import specs  # noqa: E402  (the payload -> card spec mapping, standard library only)

try:
    import card  # noqa: E402  (Pillow)
except ImportError:
    card = None

CONFIG = os.environ.get("HS_HOOK_CONFIG", "/etc/hs-matrix-hook.json")
STATE = os.environ.get("HS_HOOK_STATE", "/var/lib/hs-matrix-hook")
ROOM_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


# ── markdown -> Matrix HTML ──
# Matrix servers do not render markdown: a formatted message carries the markdown as `body` (the
# fallback) and HTML as `formatted_body`. Only what the messages use: **bold**, *italic*, `code`,
# [text](https://link), "- " lists, "### " headings. A backslash escapes the next character.
ESC_SET, esc = specs.ESC_SET, specs.esc


PH = "@@%d@@"


def md_inline(s):
    s = html.escape(s, quote=False)
    stash = []

    def keep(text):
        stash.append(text)
        return PH % (len(stash) - 1)

    s = re.sub(r"\\([" + ESC_SET + "])", lambda m: keep(m.group(1)), s)
    s = re.sub(r"`([^`]+)`", lambda m: keep("<code>%s</code>" % m.group(1)), s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^\s)]+)\)", r'<a href="\2">\1</a>', s)
    return re.sub(r"@@(\d+)@@", lambda m: stash[int(m.group(1))], s)


def md_html(text):
    out = []          # (kind, html): kind is "text", "list" or "block"
    items = []

    def flush():
        if items:
            out.append(("list", "<ul>%s</ul>" % "".join("<li>%s</li>" % i for i in items)))
            items.clear()

    for line in text.split("\n"):
        if re.match(r"^\s*[-*] ", line):
            items.append(md_inline(re.sub(r"^\s*[-*] ", "", line)))
            continue
        flush()
        h = re.match(r"^(#{1,6}) (.+)$", line)
        if h:
            out.append(("block", "<h%d>%s</h%d>" % (len(h.group(1)), md_inline(h.group(2)), len(h.group(1)))))
        elif line.strip():
            out.append(("text", md_inline(line)))
    flush()
    result = ""
    for i, (kind, part) in enumerate(out):
        if i and kind == "text" and out[i - 1][0] == "text":
            result += "<br>"
        result += part
    return result


# ── cards ──
def fetch_poster(url):
    """The poster's bytes (cached on disk), or None: a card without one still looks right."""
    if not url or not url.startswith(("http://", "https://")):
        return None
    cache = os.path.join(STATE, "posters", hashlib.sha1(url.encode()).hexdigest())
    try:
        with open(cache, "rb") as f:
            return f.read()
    except OSError:
        pass
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "hs-matrix-hook"}), timeout=15) as r:
            data = r.read(5_000_000)
    except (urllib.error.URLError, OSError, ValueError):
        return None
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, "wb") as f:
            f.write(data)
    except OSError:
        pass
    return data


def make_card(spec):
    """PNG bytes for a card spec, or None (no Pillow, cards switched off, or drawing failed)."""
    if card is None or CARDS_OFF:
        return None
    try:
        spec = dict(spec, poster=fetch_poster(spec.get("poster_url")), time=specs.now_text(TZ))
        return card.render(spec, random.Random())
    except Exception as e:   # a broken card must never lose the notification
        sys.stderr.write("card failed: %s\n" % e)
        return None


CARDS_OFF = False
CARD_W = 900   # the width a card is declared with; Element lays the image out by it (the pixels stay 1800x600)
TZ = None


# ── Matrix ──
class MatrixError(Exception):
    def __init__(self, status, text):
        super().__init__("%s %s" % (status, text))
        self.status = status
        self.retry_ms = 1000
        try:   # a 429 says how long to wait
            self.retry_ms = int(json.loads(text).get("retry_after_ms", 1000))
        except (ValueError, AttributeError, TypeError):
            pass


class Matrix:
    def __init__(self, cfg):
        self.base = cfg["homeserver"].rstrip("/")
        self.user = cfg["bot_user"]
        self.password = cfg["bot_password"]
        self.owner = cfg.get("owner", "")
        self.read_only = cfg.get("read_only") is not False
        self.token = None
        self.lock = threading.Lock()
        self.rooms_file = os.path.join(STATE, "rooms.json")
        try:
            with open(self.rooms_file) as f:
                self.rooms = json.load(f)
        except (OSError, ValueError):
            self.rooms = {}

    def request(self, method, path, body=None, auth=True, raw=None, timeout=20):
        data = json.dumps(body).encode() if body is not None else raw
        headers = {"Content-Type": raw and "image/png" or "application/json"}
        if auth:
            headers["Authorization"] = "Bearer %s" % self.token
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            raise MatrixError(e.code, e.read().decode("utf-8", "replace")[:500])
        except (urllib.error.URLError, OSError) as e:
            raise MatrixError(0, str(e))

    def login(self):
        user = self.user.lstrip("@").split(":")[0]
        r = self.request("POST", "/_matrix/client/v3/login", {
            "type": "m.login.password", "identifier": {"type": "m.id.user", "user": user},
            "password": self.password}, auth=False)
        self.token = r["access_token"]

    def call(self, method, path, body=None, raw=None, timeout=20):
        if not self.token:
            self.login()
        try:
            return self.request(method, path, body, raw=raw, timeout=timeout)
        except MatrixError as e:
            if e.status != 401:
                raise
            self.login()
            return self.request(method, path, body, raw=raw, timeout=timeout)

    def save_rooms(self):
        os.makedirs(STATE, exist_ok=True)
        tmp = self.rooms_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.rooms, f)
        os.replace(tmp, self.rooms_file)

    def room(self, name, fresh=False):
        if not fresh and name in self.rooms:
            return self.rooms[name]
        body = {"name": name.replace("-", " ").title(), "preset": "private_chat",
                "topic": "Messages from hs-matrix-hook"}
        if self.owner:
            body["invite"] = [self.owner]
        if self.read_only and self.owner:
            body["power_level_content_override"] = self.read_only_levels({})
        room_id = self.call("POST", "/_matrix/client/v3/createRoom", body)["room_id"]
        self.rooms[name] = room_id
        self.save_rooms()
        return room_id

    def read_only_levels(self, levels):
        """Power levels in which only the bot (100) writes: the owner (50) can delete messages and react, not post."""
        want = dict(levels)
        want["events_default"] = 100
        want["events"] = dict(levels.get("events") or {}, **{"m.reaction": 0})
        want["users"] = dict(levels.get("users") or {})
        if self.owner and want["users"].get(self.owner, 0) < 50:
            want["users"][self.owner] = 50
        return want

    def ensure_read_only(self, room_id):
        """Make an existing room read-only for the owner (rooms made before this existed)."""
        path = "/_matrix/client/v3/rooms/%s/state/m.room.power_levels" % urllib.parse.quote(room_id, safe="")
        levels = self.call("GET", path)
        want = self.read_only_levels(levels)
        if want != levels:
            self.call("PUT", path, want)

    def ensure_commands_room(self):
        """The room where the owner types commands: a private, unencrypted chat the bot makes and invites to."""
        with self.lock:
            if self.rooms.get("_commands"):
                return self.rooms["_commands"]
            body = {"name": "Homeserver bot", "preset": "private_chat", "is_direct": True,
                    "topic": "Commands for the hook: type help"}
            if self.owner:
                body["invite"] = [self.owner]
            self.rooms["_commands"] = self.call("POST", "/_matrix/client/v3/createRoom", body)["room_id"]
            self.save_rooms()
            return self.rooms["_commands"]

    def send(self, name, markdown):
        return self.deliver(name, self.text_content(markdown))

    @staticmethod
    def text_content(markdown):
        return {"msgtype": "m.text", "body": markdown, "format": "org.matrix.custom.html", "formatted_body": md_html(markdown)}

    def put_message(self, room_id, content):
        """One message into a room we know by id; returns its event id."""
        r = self.call("PUT", "/_matrix/client/v3/rooms/%s/send/m.room.message/%s" % (
            urllib.parse.quote(room_id, safe=""), uuid.uuid4().hex), content)
        return r.get("event_id")

    def send_image(self, name, png, alt):
        """A card: uploaded to the media repository, then posted as an image whose alt text is the markdown."""
        with self.lock:
            uri = self.call("POST", "/_matrix/media/v3/upload?filename=card.png", raw=png)["content_uri"]
        return self.deliver(name, {"msgtype": "m.image", "body": alt.replace("**", "").replace("`", ""), "url": uri,
                                   "info": {"mimetype": "image/png", "w": CARD_W, "h": CARD_W // 3, "size": len(png)}})

    def deliver(self, name, content):
        with self.lock:
            for attempt in (0, 1):
                room_id = self.room(name, fresh=bool(attempt))
                try:
                    return self.put_message(room_id, content)
                except MatrixError as e:
                    if attempt or e.status not in (403, 404):   # the bot was removed from the room: make a new one once
                        raise


MUTES = None
SEEN = {}


def post_event(matrix, room, payload, respect_mute=True):
    """Post a webhook payload to a room. Returns "posted", "ignored" (an event we do not show) or "muted"."""
    spec = specs.spec_for(payload)
    if isinstance(payload, dict) and "text" in payload:
        text, png = str(payload["text"]), None
    elif spec is None:
        return "ignored"
    elif respect_mute and MUTES is not None and MUTES.is_muted(spec["service"]):
        return "muted"
    else:
        text, png = specs.spec_text(spec), make_card(spec)
    if png:
        matrix.send_image(room, png, text)
    else:
        matrix.send(room, text)
    if spec is not None:
        SEEN[spec["service"]] = time.time()
    return "posted"


def make_handler(cfg, matrix):
    secret = cfg["secret"]

    class Handler(BaseHTTPRequestHandler):
        server_version = "hs-matrix-hook"

        def log_message(self, fmt, *args):
            sys.stderr.write("%s\n" % re.sub(r"/hook/[^/\s]+/", "/hook/***/", fmt % args))

        def reply(self, status, obj):
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/healthz":
                self.reply(200, {"ok": True, "cards": card is not None and not CARDS_OFF})
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self):
            m = re.match(r"^/hook/([^/]+)/([^/?]+)$", self.path)
            if not m or not hmac.compare_digest(m.group(1), secret):
                return self.reply(403 if m else 404, {"error": "forbidden" if m else "not found"})
            room = m.group(2)
            if not ROOM_RE.match(room):
                return self.reply(400, {"error": "room names are a-z, 0-9 and -"})
            try:
                length = int(self.headers.get("Content-Length", 0))
                if length > 1_000_000:
                    return self.reply(413, {"error": "too large"})
                payload = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return self.reply(400, {"error": "not JSON"})
            try:
                result = post_event(matrix, room, payload)
            except (MatrixError, KeyError) as e:
                sys.stderr.write("Matrix refused: %s\n" % e)
                return self.reply(502, {"error": "matrix: %s" % e})
            self.reply(200, {"ok": True, "posted": result == "posted", "muted": result == "muted"})

    return Handler


def main():
    with open(CONFIG) as f:
        cfg = json.load(f)
    global CARDS_OFF, TZ
    CARDS_OFF = cfg.get("cards") is False
    global CARD_W
    CARD_W = max(300, min(1800, int(cfg.get("card_width", 900))))
    if cfg.get("timezone"):
        try:
            import zoneinfo
            TZ = zoneinfo.ZoneInfo(cfg["timezone"])
        except Exception as e:
            sys.stderr.write("timezone %r not usable: %s\n" % (cfg["timezone"], e))
    sys.stderr.write("cards: %s\n" % ("on" if card is not None and not CARDS_OFF else "off (text only)"))
    matrix = Matrix(cfg)
    global MUTES
    MUTES = bot.Mutes(os.path.join(STATE, "mutes.json"))
    if cfg.get("owner"):
        chat = bot.Bot(matrix, cfg["owner"], TZ, MUTES, SEEN, lambda rid, text: matrix.put_message(rid, matrix.text_content(text)),
                       lambda room, payload: post_event(matrix, room, payload, respect_mute=False),
                       lambda: card is not None and not CARDS_OFF, STATE, int(cfg.get("confirm_seconds", 60)))
        threading.Thread(target=chat.run, daemon=True).start()
    server = ThreadingHTTPServer((cfg.get("bind", "0.0.0.0"), int(cfg.get("port", 8090))), make_handler(cfg, matrix))
    sys.stderr.write("listening on %s:%s\n" % server.server_address)
    server.serve_forever()


if __name__ == "__main__":
    main()
