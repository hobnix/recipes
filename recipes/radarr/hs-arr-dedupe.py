#!/usr/bin/env python3
"""Films with two files in one folder (say 2160p and 1080p): the lower resolution goes, after a grace period.

  hs-arr-dedupe.py [--dry-run] [--days N] [--media /media/movies] [--state DIR]

Why a script and not a Maintainerr rule: Maintainerr acts on a whole film (Radarr/Jellyfin see one item with
two versions), so a rule that "deletes the FullHD one" would delete the 4K file with it. Here the unit is the FILE.

Rules (each run):
  * a folder is looked at only for films directly under --media, files directly in the folder, videos of 100 MB
    or more (samples and trailers are smaller or named so); folder `extras` and a file `.keep-both` in the
    film's folder are left alone (that is the veto: touch <film folder>/.keep-both)
  * the resolution is the height of the first video stream (ffprobe); the file(s) with the highest value stay,
    a file with a strictly lower one is a candidate; equal heights are never touched
  * a candidate is only announced the first time (ntfy + Matrix, tagged "Maintainerr (Script)"), and deleted
    when it has been a candidate for --days days (default 14) and the better file is still there
  * after a delete Radarr is asked to rescan the film (best effort: its API key is read from its config.xml)
State (pending.json) is in --state. --dry-run prints and changes nothing, sends nothing.
Test knobs: HS_DEDUPE_FFPROBE, HS_DEDUPE_NOTIFY (command, default hs-media-notify.py next to this file),
HS_DEDUPE_NOW (YYYY-MM-DD), HS_DEDUPE_NO_RADARR=1.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.request
from datetime import date, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
VIDEO = (".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".wmv")
MIN_BYTES = 100 * 1024 * 1024


def today():
    forced = os.environ.get("HS_DEDUPE_NOW")
    return datetime.strptime(forced, "%Y-%m-%d").date() if forced else date.today()


def height(path):
    cmd = shlex.split(os.environ.get("HS_DEDUPE_FFPROBE", "ffprobe"))
    try:
        out = subprocess.run(cmd + ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=height",
                              "-of", "csv=p=0", path], capture_output=True, text=True, timeout=60).stdout.strip()
        return int(out.split()[0].split(",")[0])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return 0


def label(h):
    return "2160p (4K)" if h >= 2000 else "1440p" if h >= 1400 else "1080p" if h >= 1000 else "720p" if h >= 700 else "%dp" % h


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024


def film_name(folder):
    """'Heat (1995)' -> ('Heat', '1995')."""
    base = os.path.basename(folder.rstrip("/"))
    m = re.match(r"^(.*?)\s*\((\d{4})\)", base)
    return (m.group(1), m.group(2)) if m else (base, "")


def candidates(media):
    """[(folder, keep_path, keep_height, drop_path, drop_height)] for every film with two resolutions."""
    found = []
    try:
        folders = sorted(os.scandir(media), key=lambda e: e.name)
    except OSError as e:
        sys.exit("cannot read %s: %s" % (media, e))
    for entry in folders:
        if not entry.is_dir(follow_symlinks=False) or entry.name.lower() == "extras":
            continue
        if os.path.exists(os.path.join(entry.path, ".keep-both")):
            continue
        files = [f for f in os.scandir(entry.path)
                 if f.is_file() and f.name.lower().endswith(VIDEO) and f.stat().st_size >= MIN_BYTES]
        if len(files) < 2:
            continue
        heights = {f.path: height(f.path) for f in files}
        if min(heights.values()) == 0:      # a file ffprobe cannot read: no decision for this film
            continue
        best = max(heights.values())
        keep = max((p for p in heights if heights[p] == best), key=lambda p: os.path.getsize(p))
        for p, h in heights.items():
            if h < best:
                found.append((entry.path, keep, best, p, h))
    return found


def notify(*args):
    cmd = os.environ.get("HS_DEDUPE_NOTIFY") or os.path.join(HERE, "hs-media-notify.py")
    try:
        subprocess.run(shlex.split(cmd) + ["send", "--service", "maintainerr", *args], timeout=180)
    except (OSError, subprocess.SubprocessError) as e:
        sys.stderr.write("notify failed: %s\n" % e)


def rescan(folder):
    """Ask Radarr to look at the film's folder again, so it adopts the file that is left."""
    if os.environ.get("HS_DEDUPE_NO_RADARR"):
        return
    try:
        with open("/opt/radarr/config/config.xml") as f:
            key = re.search(r"<ApiKey>([^<]+)</ApiKey>", f.read()).group(1)
        base = "http://127.0.0.1:7878/api/v3"

        def call(path, data=None):
            req = urllib.request.Request(base + path, data=json.dumps(data).encode() if data else None,
                                         headers={"X-Api-Key": key, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        movie = next(m for m in call("/movie") if (m.get("path") or "").rstrip("/") == folder.rstrip("/"))
        call("/command", {"name": "RescanMovie", "movieId": movie["id"]})
    except Exception as e:   # noqa: BLE001 - best effort
        sys.stderr.write("Radarr rescan skipped: %s\n" % e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--media", default="/media/movies")
    ap.add_argument("--state", default="/opt/radarr/dedupe")
    a = ap.parse_args()

    os.makedirs(a.state, exist_ok=True)
    pending_file = os.path.join(a.state, "pending.json")
    try:
        with open(pending_file) as f:
            pending = json.load(f)
    except (OSError, ValueError):
        pending = {}

    now = today()
    cands = candidates(a.media)
    live = {c[3] for c in cands}
    next_pending = {p: v for p, v in pending.items() if p in live}
    deleted = planned = 0

    for folder, keep, kh, drop, dh in cands:
        title, year = film_name(folder)
        size = os.path.getsize(drop)
        first = datetime.strptime(next_pending.get(drop, {}).get("first", now.isoformat()), "%Y-%m-%d").date()
        due = (now - first).days >= a.days
        known = drop in next_pending
        if a.dry_run:
            print("%-45s keep %-10s drop %-10s %s  (%s)" % (title + (" (%s)" % year if year else ""), label(kh), label(dh), human(size),
                  "deletes now" if due and known else "since %s, deletes %s" % (first, first.fromordinal(first.toordinal() + a.days)) if known else "new, deletes after %d days" % a.days))
            continue
        if known and due:
            if not os.path.exists(keep):
                next_pending.pop(drop, None)
                continue
            try:
                os.remove(drop)
            except OSError as e:
                sys.stderr.write("cannot delete %s: %s\n" % (drop, e))
                continue
            next_pending.pop(drop, None)
            deleted += 1
            notify("--event", "deleted", "--title", title, "--sub", year, "--field", "Kept=" + label(kh), "--field", "Deleted=" + label(dh),
                   "--field", "Freed=" + human(size), "--footer", os.path.basename(drop))
            rescan(folder)
        elif not known:
            next_pending[drop] = {"first": now.isoformat(), "keep": keep}
            planned += 1
            when = date.fromordinal(now.toordinal() + a.days).isoformat()
            notify("--event", "planned", "--title", title, "--sub", year, "--field", "Keep=" + label(kh), "--field", "Delete=" + label(dh),
                   "--field", "Size=" + human(size), "--field", "On=" + when, "--footer", os.path.basename(drop) + "  (veto: touch .keep-both in the folder)")

    if a.dry_run:
        if not cands:
            print("no film has two resolutions")
        return 0
    tmp = pending_file + ".new"
    with open(tmp, "w") as f:
        json.dump(next_pending, f, indent=1)
    os.replace(tmp, pending_file)
    print("%d announced, %d deleted, %d waiting" % (planned, deleted, len(next_pending)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
