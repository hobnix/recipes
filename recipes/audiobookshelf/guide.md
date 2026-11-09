# Audiobookshelf: audiobooks and podcasts on phone and browser

Audiobookshelf streams the audiobooks and podcasts in your share `media` to browsers and to the official phone apps (Android, iOS). It remembers where each person stopped, has users with their own progress, fetches covers and descriptions, and can download podcast episodes.

## Before you start
- A running server with the share `media` (created by the `jellyfin` recipe). The recipe makes the folders `audiobooks` and `podcasts` in it.
- Books in `/media/audiobooks`, one folder per book (`Author/Title`), or copy them there over Samba.

## Set it up
```bash
sudo hs recipe audiobookshelf
```

The recipe asks where it runs: in a container of its own (`lxc`) or, when Docker is on (`hs docker enable`), as an app inside the container `docker`. Both give the same page on port 13378.

Open the page and create the root login at once: the first person who opens it becomes root. Then add two libraries in Settings: `/audiobooks` (type Audiobooks) and `/podcasts` (type Podcasts).

Audiobookshelf may write next to your books (covers, `metadata.json`, downloaded podcast episodes), so it has the folders read-write, unlike Navidrome.

## Make it public
Audiobookshelf has its own logins, so the recipe offers a public name in the step Service (needs the gateway and `proxyDomains`). Do the first login before you say yes, give every person their own user and use a long password. The phone apps use a websocket: if the page loads but the app shows "offline", the proxy in front does not pass websockets on. Apply it with `hs services apply`.

## Backup
The container (or the app folder in the container `docker`) is in the nightly backup, with a safe copy of the database. The books themselves are in the share `media`.

Not tested on hardware yet.
