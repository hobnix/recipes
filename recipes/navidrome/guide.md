# Navidrome: your music on phone and browser

Navidrome streams the music in your share `media` to browsers and to any Subsonic app (Symfonium, DSub, Substreamer). It has users, playlists and play counts of its own.

## Before you start
- A running server with the share `media` (created by the `jellyfin` recipe). Navidrome reads `/media/music` and never changes it.
- Music in that folder. The `lidarr` recipe fills it; you can also copy albums there yourself.

## Set it up
```bash
sudo hs recipe navidrome
```

The recipe asks where it runs: in a container of its own (`lxc`) or, when Docker is on (`hs docker enable`), as an app inside the container `docker`. Both give the same page on port 4533.

Open the page and create the admin login at once: the first person who opens it becomes admin. Navidrome scans the library every hour.

## Make it public
Navidrome has its own logins, so the recipe offers a public name in the step Service (needs the gateway and `proxyDomains`). Do the first login before you say yes, give every person their own user and use a long password. Apply it with `hs services apply`.

## Backup
The container (or the app folder in the container `docker`) is in the nightly backup, with a safe copy of the database. The music itself is in the share `media`.

Not tested on hardware yet.
