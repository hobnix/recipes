"""The parsing of the Matrix hook's chat commands (matrix-card/bot.py): times, durations, `clear` and `mute`
arguments. usage: matrix-chat-test.py <matrix-card dir>"""
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, sys.argv[1])
import bot  # noqa: E402

TZ = timezone(timedelta(hours=2))
NOW = datetime(2026, 10, 12, 15, 30, tzinfo=TZ)
n = 0


def eq(what, got, want):
    global n
    n += 1
    if got != want:
        print("FAIL %s: got %r, want %r" % (what, got, want))
        sys.exit(1)


def ms(dt):
    return int(dt.timestamp() * 1000)


eq("duration 90m", bot.parse_duration("90m"), timedelta(minutes=90))
eq("duration 2w", bot.parse_duration("2w"), timedelta(weeks=2))
eq("duration junk", bot.parse_duration("soon"), None)
eq("7d ago", bot.parse_time("7d", NOW), NOW - timedelta(days=7))
eq("12h ago", bot.parse_time("12h", NOW), NOW - timedelta(hours=12))
eq("a date is the start of the day", bot.parse_time("2026-10-01", NOW), datetime(2026, 10, 1, tzinfo=TZ))
eq("a date as an end is the last moment of the day", bot.parse_time("2026-10-01", NOW, end=True), datetime(2026, 10, 2, tzinfo=TZ) - timedelta(milliseconds=1))
eq("date and time", bot.parse_time("2026-10-01 14:30", NOW), datetime(2026, 10, 1, 14, 30, tzinfo=TZ))
eq("date T time", bot.parse_time("2026-10-01T14:30", NOW), datetime(2026, 10, 1, 14, 30, tzinfo=TZ))
eq("yesterday", bot.parse_time("yesterday", NOW), datetime(2026, 10, 11, tzinfo=TZ))
eq("today", bot.parse_time("today", NOW), datetime(2026, 10, 12, tzinfo=TZ))
eq("now", bot.parse_time("now", NOW), NOW)
eq("not a date", bot.parse_time("2026-13-45", NOW), None)
eq("not a time at all", bot.parse_time("banana", NOW), None)

start, end, err = bot.parse_clear("", NOW)
eq("clear alone: everything up to now", (start, end, err), (None, ms(NOW), None))
start, end, err = bot.parse_clear("to 7d", NOW)
eq("clear to 7d", (start, end, err), (None, ms(NOW - timedelta(days=7)), None))
start, end, err = bot.parse_clear("from 2026-10-01 to 2026-10-05", NOW)
eq("clear from date to date", (start, end), (ms(datetime(2026, 10, 1, tzinfo=TZ)), ms(datetime(2026, 10, 6, tzinfo=TZ)) - 1))
start, end, err = bot.parse_clear("from 2026-10-01 14:30 to 2026-10-05 08:00", NOW)
eq("clear with times", (start, end), (ms(datetime(2026, 10, 1, 14, 30, tzinfo=TZ)), ms(datetime(2026, 10, 5, 8, tzinfo=TZ))))
start, end, err = bot.parse_clear("from 3d", NOW)
eq("only from: up to now", (start, end), (ms(NOW - timedelta(days=3)), ms(NOW)))
eq("a word before the keywords", bot.parse_clear("everything", NOW)[2] is not None, True)
eq("from after to", bot.parse_clear("from 1d to 3d", NOW)[2] is not None, True)
eq("unreadable time", bot.parse_clear("to nonsense", NOW)[2] is not None, True)

eq("mute", bot.parse_mute("radarr 3h")[:2], (["radarr"], timedelta(hours=3)))
eq("mute default", bot.parse_mute("sonarr")[:2], (["sonarr"], timedelta(hours=2)))
eq("mute all", bot.parse_mute("all 30m")[0], list(bot.SERVICES))
eq("mute without a service", bot.parse_mute("")[2] is not None, True)
eq("mute with a bad duration", bot.parse_mute("radarr soon")[2] is not None, True)
print("%d checks ok" % n)
