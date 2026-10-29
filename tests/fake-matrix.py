#!/usr/bin/env python3
"""A stand-in for the Matrix client API, enough for hs-matrix-hook (tests/matrix-hook.sh).

usage: fake-matrix.py <port file> <log file>
Writes its port to <port file>; every login, createRoom, upload, poster fetch, message and redaction is
one JSON line in <log file>.

The API the hook uses: login, createRoom (with power levels), the power levels of a room, media upload, sending messages, /sync (long poll, capped at
0.3 s here), /messages (history, newest first) and redactions. Everything sent lands in an event store
that /sync and /messages read.

Test helpers:
  POST /_test/expire              every token becomes invalid (the next call gets 401); several receivers may be logged in at once
  POST /_test/say                 {"room","sender","body","ts"?}: a message from somebody (the owner typing a command)
  POST /_test/seed                {"room","ts_list":[ms,...]}: old messages of the bot
  POST /_test/ratelimit           {"n": 3}: the next n redactions answer 429 (retry after 50 ms)
  GET  /_test/events?room=<id>    {"live": [ids], "redacted": [ids]}
  GET  /poster.png                a small image
"""
import json
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, log_file = sys.argv[1], sys.argv[2]
lock = threading.Lock()
state = {"logins": 0, "valid": set(), "rooms": 0, "events": [], "ratelimit": 0, "levels": {}}


def log(entry):
    with lock:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def add_event(room, sender, content, ts=None, etype="m.room.message"):
    with lock:
        eid = "$e%d" % (len(state["events"]) + 1)
        state["events"].append({"event_id": eid, "room_id": room, "sender": sender, "type": etype, "content": content,
                                "origin_server_ts": int(ts if ts is not None else time.time() * 1000), "redacted": False})
        return eid


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def authed(self):
        if self.headers.get("Authorization", "")[7:] not in state["valid"]:
            self.reply(401, {"errcode": "M_UNKNOWN_TOKEN"})
            return False
        return True

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        if url.path == "/poster.png":
            from PIL import Image
            import io
            out = io.BytesIO()
            Image.new("RGB", (200, 300), (120, 60, 40)).save(out, "PNG")
            data = out.getvalue()
            log({"poster": len(data)})
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif re.match(r"^/_matrix/client/v3/rooms/[^/]+/state/m\.room\.power_levels$", url.path):
            if not self.authed():
                return
            room = urllib.parse.unquote(url.path.split("/")[5])
            self.reply(200, state["levels"].get(room, {"users": {"@hs-bot:test": 100}, "events_default": 0}))
        elif url.path == "/_test/events":
            room = q["room"][0]
            with lock:
                evs = [e for e in state["events"] if e["room_id"] == room]
            self.reply(200, {"live": [e["event_id"] for e in evs if not e["redacted"]], "redacted": [e["event_id"] for e in evs if e["redacted"]]})
        elif url.path == "/_matrix/client/v3/sync":
            if not self.authed():
                return
            since = q.get("since", [None])[0]
            with lock:
                total = len(state["events"])
            if since is None:
                return self.reply(200, {"next_batch": str(total), "rooms": {}})
            deadline = time.time() + 0.3
            while True:
                with lock:
                    new = state["events"][int(since):]
                if new or time.time() > deadline:
                    break
                time.sleep(0.05)
            join = {}
            for e in new:
                join.setdefault(e["room_id"], {"timeline": {"events": []}})["timeline"]["events"].append(
                    {"event_id": e["event_id"], "sender": e["sender"], "type": e["type"], "content": e["content"], "origin_server_ts": e["origin_server_ts"]})
            self.reply(200, {"next_batch": str(int(since) + len(new)), "rooms": {"join": join}})
        else:
            m = re.match(r"^/_matrix/client/v3/rooms/([^/]+)/messages$", url.path)
            if not m:
                return self.reply(404, {})
            if not self.authed():
                return
            room = urllib.parse.unquote(m.group(1))
            limit = int(q.get("limit", ["10"])[0])
            with lock:
                evs = [e for e in state["events"] if e["room_id"] == room and e["type"] == "m.room.message"]
            evs.sort(key=lambda e: -e["origin_server_ts"])
            start = int(q.get("from", ["0"])[0])
            chunk = evs[start:start + limit]
            out = []
            for e in chunk:
                item = {"event_id": e["event_id"], "sender": e["sender"], "type": e["type"], "origin_server_ts": e["origin_server_ts"],
                        "content": {} if e["redacted"] else e["content"], "unsigned": {}}
                if e["redacted"]:
                    item["unsigned"]["redacted_because"] = {"type": "m.room.redaction"}
                out.append(item)
            res = {"chunk": out}
            if start + limit < len(evs):
                res["end"] = str(start + limit)
            self.reply(200, res)

    def do_POST(self):
        if self.path.startswith("/_matrix/media/v3/upload"):
            if not self.authed():
                return
            n = int(self.headers.get("Content-Length", 0))
            data = self.rfile.read(n)
            log({"upload": len(data), "png": data[:8] == bytes([137, 80, 78, 71, 13, 10, 26, 10]), "type": self.headers.get("Content-Type")})
            return self.reply(200, {"content_uri": "mxc://test/media1"})
        if self.path == "/_test/expire":
            state["valid"] = set()
            return self.reply(200, {})
        if self.path == "/_test/say":
            b = self.body()
            eid = add_event(b["room"], b["sender"], {"msgtype": "m.text", "body": b["body"]}, b.get("ts"))
            return self.reply(200, {"event_id": eid})
        if self.path == "/_test/seed":
            b = self.body()
            ids = [add_event(b["room"], "@hs-bot:test", {"msgtype": "m.text", "body": "old %d" % i}, ts) for i, ts in enumerate(b["ts_list"])]
            return self.reply(200, {"ids": ids})
        if self.path == "/_test/ratelimit":
            state["ratelimit"] = self.body()["n"]
            return self.reply(200, {})
        if self.path == "/_matrix/client/v3/login":
            b = self.body()
            if b.get("password") != "bot-pass":
                return self.reply(403, {"errcode": "M_FORBIDDEN"})
            state["logins"] += 1
            token = "tok%d" % state["logins"]
            state["valid"].add(token)
            log({"login": b["identifier"]["user"]})
            return self.reply(200, {"access_token": token})
        if self.path == "/_matrix/client/v3/createRoom":
            if not self.authed():
                return
            b = self.body()
            state["rooms"] += 1
            rid = "!room%d:test" % state["rooms"]
            log({"createRoom": b.get("name"), "invite": b.get("invite"), "direct": b.get("is_direct"), "levels": b.get("power_level_content_override")})
            if b.get("power_level_content_override"):
                state["levels"][rid] = b["power_level_content_override"]
            return self.reply(200, {"room_id": rid})
        self.reply(404, {})

    def do_PUT(self):
        m = re.match(r"^/_matrix/client/v3/rooms/([^/]+)/send/m\.room\.message/[^/]+$", self.path)
        r = re.match(r"^/_matrix/client/v3/rooms/([^/]+)/redact/([^/]+)/[^/]+$", self.path)
        pl = re.match(r"^/_matrix/client/v3/rooms/([^/]+)/state/m\.room\.power_levels$", self.path)
        if pl:
            if not self.authed():
                return
            room = urllib.parse.unquote(pl.group(1))
            state["levels"][room] = self.body()
            log({"powerlevels": room, "content": state["levels"][room]})
            return self.reply(200, {"event_id": "$state"})
        if r:
            if not self.authed():
                return
            self.body()
            with lock:
                if state["ratelimit"] > 0:
                    state["ratelimit"] -= 1
                    limited = True
                else:
                    limited = False
            if limited:
                return self.reply(429, {"errcode": "M_LIMIT_EXCEEDED", "retry_after_ms": 50})
            eid = urllib.parse.unquote(r.group(2))
            with lock:
                for e in state["events"]:
                    if e["event_id"] == eid:
                        e["redacted"] = True
            log({"redact": eid})
            return self.reply(200, {"event_id": "$redaction"})
        if not m:
            return self.reply(404, {})
        if not self.authed():
            return
        b = self.body()
        room = urllib.parse.unquote(m.group(1))
        eid = add_event(room, "@hs-bot:test", b)
        log({"room": room, "msgtype": b.get("msgtype"), "body": b.get("body"), "format": b.get("format"),
             "html": b.get("formatted_body"), "url": b.get("url"), "info": b.get("info"), "event_id": eid})
        self.reply(200, {"event_id": eid})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
