"""Smoke test of the notification cards: one sample payload per card of the design (29), turned into a spec
by specs.py and drawn by card.py. Each must give a 1800x600 PNG.

usage: matrix-card-smoke.py <matrix-card dir> [<contact sheet .png> [<folder with the design's PNGs> [<card numbers, e.g. 01,09>]]]
With a sheet path the cards are also written as one picture (two columns with the design's PNGs next to
them when that folder is given), for looking at them.
"""
import io
import random
import sys

sys.path.insert(0, sys.argv[1])
import card  # noqa: E402
import specs  # noqa: E402
from PIL import Image  # noqa: E402

GB = 1024 ** 3
MOVIE = {"title": "Dune: Part Two", "year": 2024, "folderPath": "/movies/Dune Part Two (2024)"}
SHOW = {"title": "Severance", "year": 2022, "path": "/tv/Severance (2022)", "type": "Standard"}

SAMPLES = {
    "01-radarr-grab": {"eventType": "Grab", "movie": MOVIE, "release": {"quality": "WEBDL-2160p", "size": 24.3 * GB, "indexer": "NZBgeek", "releaseTitle": "Dune.Part.Two.2024.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX"}, "downloadClient": "SABnzbd"},
    "02-radarr-import": {"eventType": "Download", "movie": MOVIE, "movieFile": {"quality": "WEBDL-2160p", "size": 24.3 * GB, "releaseGroup": "FLUX", "path": "/movies/Dune Part Two (2024)/Dune Part Two (2024) [2160p].mkv"}},
    "03-radarr-upgrade": {"eventType": "Download", "isUpgrade": True, "movie": {"title": "Oppenheimer", "year": 2023}, "movieFile": {"quality": "Remux-2160p", "size": 71.8 * GB}, "deletedFiles": [{"quality": "Bluray-1080p"}], "customFormatInfo": {"customFormatScore": 1250}, "release": {"releaseTitle": "Oppenheimer.2023.UHD.BluRay.2160p.REMUX.HDR.DV.TrueHD.Atmos-FraMeSToR"}},
    "04-radarr-rename": {"eventType": "Rename", "movie": {"title": "Past Lives", "year": 2023}, "renamedMovieFiles": [{"previousRelativePath": "Past.Lives.2023.1080p.WEB.h264-ETHEL.mkv", "relativePath": "Past Lives (2023) [WEBDL-1080p].mkv"}]},
    "05-radarr-movie-added": {"eventType": "MovieAdded", "movie": {"title": "Poor Things", "year": 2023, "folderPath": "/movies/Poor Things (2023)", "tmdbId": 792307, "imdbId": "tt14230458"}, "addMethod": "Manual"},
    "06-radarr-movie-delete": {"eventType": "MovieDelete", "movie": {"title": "Morbius", "year": 2022, "folderPath": "/movies/Morbius (2022)"}, "deletedFiles": True, "movieFolderSize": 8.4 * GB},
    "07-radarr-movie-file-delete": {"eventType": "MovieFileDelete", "deleteReason": "Manual", "movie": {"title": "Tenet", "year": 2020}, "movieFile": {"quality": "Bluray-1080p", "size": 14.2 * GB, "path": "/movies/Tenet (2020)/Tenet (2020) [Bluray-1080p].mkv"}},
    "08-radarr-file-delete-for-upgrade": {"eventType": "MovieFileDelete", "deleteReason": "Upgrade", "movie": {"title": "Oppenheimer", "year": 2023}, "movieFile": {"quality": "Bluray-1080p", "size": 12.1 * GB, "path": "/movies/Oppenheimer (2023)/Oppenheimer (2023) [Bluray-1080p].mkv"}},
    "09-radarr-health-issue": {"eventType": "Health", "level": "Error", "type": "IndexerStatusCheck", "message": "All indexers are unavailable due to failures for more than 6 hours", "instanceName": "Radarr"},
    "10-radarr-health-restored": {"eventType": "HealthRestored", "level": "Ok", "type": "IndexerStatusCheck", "message": "Previous issue cleared automatically", "instanceName": "Radarr"},
    "11-radarr-health-warning": {"eventType": "Health", "level": "Warning", "type": "RootFolderCheck", "message": "/movies has 42.1 GB free of 8 TB", "instanceName": "Radarr"},
    "12-radarr-app-update": {"eventType": "ApplicationUpdate", "message": "Update installed, service restarted", "previousVersion": "5.13.1", "newVersion": "5.14.0", "instanceName": "Radarr"},
    "13-radarr-manual-interaction": {"eventType": "ManualInteractionRequired", "movie": {"title": "Furiosa: A Mad Max Saga", "year": 2024}, "downloadClient": "qBittorrent", "downloadInfo": {"size": 18.9 * GB}, "downloadStatusMessages": [{"title": "Unknown movie", "messages": ["Found matching movie via grab history, but release was matched by ID. Manual import required."]}]},
    "14-sonarr-grab": {"eventType": "Grab", "series": SHOW, "episodes": [{"seasonNumber": 2, "episodeNumber": 3, "title": "Who Is Alive?"}], "release": {"quality": "WEBDL-2160p", "size": 6.1 * GB, "indexer": "DrunkenSlug", "releaseTitle": "Severance.S02E03.Who.Is.Alive.2160p.ATVP.WEB-DL.DDP5.1.DV.H.265-NTb"}},
    "15-sonarr-import": {"eventType": "Download", "series": {"title": "Shōgun", "year": 2024}, "episodes": [{"seasonNumber": 1, "episodeNumber": 9, "title": "Crimson Sky"}], "episodeFile": {"quality": "WEBDL-1080p", "size": 2.4 * GB, "path": "/tv/Shogun (2024)/Season 01/Shogun - S01E09 - Crimson Sky [WEBDL-1080p].mkv"}},
    "16-sonarr-upgrade": {"eventType": "Download", "isUpgrade": True, "series": {"title": "The Bear"}, "episodes": [{"seasonNumber": 3, "episodeNumber": 1, "title": "Tomorrow"}], "episodeFile": {"quality": "WEBDL-2160p", "size": 4.8 * GB}, "deletedFiles": [{"quality": "WEBDL-720p"}], "customFormatInfo": {"customFormatScore": 400}, "release": {"releaseTitle": "The.Bear.S03E01.Tomorrow.2160p.HULU.WEB-DL.DDP5.1.H.265-FLUX"}},
    "17-sonarr-import-complete": {"eventType": "ImportComplete", "series": {"title": "Andor", "path": "/tv/Andor (2022)"}, "episodes": [{"seasonNumber": 2, "episodeNumber": n, "title": "x"} for n in range(1, 13)], "episodeFiles": [{"quality": "WEBDL-2160p", "size": 4.9 * GB}] * 12, "release": {"releaseType": "SeasonPack"}},
    "18-sonarr-rename": {"eventType": "Rename", "series": {"title": "Slow Horses", "year": 2022}, "renamedEpisodeFiles": [{"previousRelativePath": "Slow.Horses.S04E01.1080p.WEB.H264-SuccessfulCrab.mkv", "relativePath": "Slow Horses - S04E01 - Identity Theft [WEBDL-1080p].mkv"}] * 6},
    "19-sonarr-series-add": {"eventType": "SeriesAdd", "series": {"title": "The Penguin", "year": 2024, "path": "/tv/The Penguin (2024)", "tvdbId": 403245, "imdbId": "tt15435876", "type": "Standard"}},
    "20-sonarr-series-delete": {"eventType": "SeriesDelete", "deletedFiles": True, "series": {"title": "Lost", "year": 2004, "path": "/tv/Lost (2004)"}},
    "21-sonarr-episode-file-delete": {"eventType": "EpisodeFileDelete", "deleteReason": "MissingFromDisk", "series": {"title": "The Last of Us"}, "episodes": [{"seasonNumber": 1, "episodeNumber": 4, "title": "Please Hold to My Hand"}], "episodeFile": {"path": "/tv/The Last of Us (2023)/Season 01/The Last of Us - S01E04.mkv"}},
    "22-sonarr-file-delete-for-upgrade": {"eventType": "EpisodeFileDelete", "deleteReason": "Upgrade", "series": {"title": "The Bear"}, "episodes": [{"seasonNumber": 3, "episodeNumber": 1, "title": "Tomorrow"}], "episodeFile": {"quality": "WEBDL-720p", "size": 1.1 * GB, "path": "/tv/The Bear (2022)/Season 03/The Bear - S03E01 - Tomorrow [WEBDL-720p].mkv"}},
    "23-sonarr-health-issue": {"eventType": "Health", "level": "Error", "type": "DownloadClientCheck", "message": "Unable to communicate with qBittorrent: connection refused (localhost:8080)", "instanceName": "Sonarr"},
    "24-sonarr-health-restored": {"eventType": "HealthRestored", "level": "Ok", "type": "DownloadClientCheck", "message": "Previous issue cleared automatically", "instanceName": "Sonarr"},
    "25-sonarr-health-warning": {"eventType": "Health", "level": "Warning", "type": "IndexerLongTermStatusCheck", "message": "NZBgeek: API limit reached, resets in 3h", "instanceName": "Sonarr"},
    "26-sonarr-app-update": {"eventType": "ApplicationUpdate", "message": "Update installed, service restarted", "previousVersion": "4.0.10", "newVersion": "4.0.11", "instanceName": "Sonarr"},
    "27-sonarr-manual-interaction": {"eventType": "ManualInteractionRequired", "series": SHOW, "episodes": [{"seasonNumber": 2, "episodeNumber": 5, "title": "x"}], "downloadClient": "qBittorrent", "downloadStatusMessages": [{"title": "Episode not in release", "messages": ["Severance.S02.2160p.ATVP.WEB-DL — 1 file could not be matched to an episode"]}]},
    "28-seerr-auto-approved": {"notification_type": "MEDIA_AUTO_APPROVED", "subject": "The Wild Robot (2024)", "media": {"media_type": "movie"}, "request": {"requestedBy_username": "maria"}},
    "29-seerr-approved": {"notification_type": "MEDIA_APPROVED", "subject": "Arcane (2021)", "media": {"media_type": "tv"}, "request": {"requestedBy_username": "jonas"}, "extra": [{"name": "Requested Seasons", "value": "2"}]},
}

sheet_path = sys.argv[2] if len(sys.argv) > 2 else None
mock_dir = sys.argv[3] if len(sys.argv) > 3 else None
rows = []
bad = []
for name, payload in SAMPLES.items():
    spec = specs.spec_for(payload)
    if spec is None:
        bad.append("%s: no spec" % name)
        continue
    spec = dict(spec, time="12:00")
    try:
        im = Image.open(io.BytesIO(card.render(spec, random.Random(7)))).convert("RGB")
    except Exception as e:
        bad.append("%s: %s" % (name, e))
        continue
    if im.size != (1800, 600):
        bad.append("%s: size %s" % (name, im.size))
    rows.append((name, im))

def mean_rgb(im):
    """The average colour of the dotted right half of a card (no text there)."""
    box = im.crop((1000, 0, 1800, 200)).resize((1, 1), Image.BOX)
    return box.getpixel((0, 0))


by_service = {}
for name, im in rows:
    by_service.setdefault(name.split("-")[1], mean_rgb(im))
r, g, b = by_service.get("radarr", (0, 0, 0))
# the dots are dim (same luminance as Sonarr's), so "yellow" means: warmer than the bare background (22, 24, 38: r - b = -16)
if not (r - b > -10 and g - b > -10):
    bad.append("the Radarr background is not yellow: %s" % (by_service.get("radarr"),))
r, g, b = by_service.get("sonarr", (0, 0, 0))
if not (b > r and b > g):
    bad.append("the Sonarr background is not blue: %s" % (by_service.get("sonarr"),))
r, g, b = by_service.get("seerr", (0, 0, 0))
if not (b > g and r > g):
    bad.append("the Seerr background is not purple: %s" % (by_service.get("seerr"),))

for b in bad:
    print("FAIL", b)
if sheet_path and rows:
    only = sys.argv[4].split(",") if len(sys.argv) > 4 else None
    picked = [(n, im) for n, im in rows if not only or n[:2] in only]
    w, h = 600, 200
    cols = 2 if mock_dir else 3
    sheet = Image.new("RGB", (w * cols, h * ((len(picked) * (2 if mock_dir else 1) + cols - 1) // cols)))
    k = 0
    for name, im in picked:
        if mock_dir:
            m = Image.open("%s/%s.png" % (mock_dir, name)).convert("RGB").resize((w, h), Image.LANCZOS)
            sheet.paste(m, ((k % cols) * w, (k // cols) * h))
            k += 1
        sheet.paste(im.resize((w, h), Image.LANCZOS), ((k % cols) * w, (k // cols) * h))
        k += 1
    sheet.save(sheet_path)
print("%d cards ok" % (len(rows)) if not bad else "%d cards, %d failed" % (len(rows), len(bad)))
sys.exit(1 if bad else 0)
