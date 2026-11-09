# DroppedNeedle: discover and request music

DroppedNeedle (called MusicSeerr before v2.0.0 of the project) is a page where people browse and discover music and ask for albums. It has users of its own and sends a request to a download client you run yourself.

## Before you start
- A running server with the share `media`. The app sees it at `/data`, so the library is `/data/music` and the downloads of SABnzbd are in `/data/downloads/usenet/complete`.
- A download client: `sabnzbd` (with an indexer from `prowlarr`) and/or slskd. Version 2 does not need Lidarr any more.
- Not a recipe task: what you request is your decision and your responsibility.

## Set it up
```bash
sudo hs recipe droppedneedle
```

The recipe asks where it runs: in a container of its own (`lxc`) or inside the container `docker`. Both give the page on port 8688.

Open the page and create the admin login at once: it is open to whoever gets there first. Then add the download client under Settings. Jellyfin, Plex or OIDC sign-in can be switched on there as well.

## Make it public
The app has its own logins, so the recipe offers a public name in the step Service. Do the first login before you say yes. Apply it with `hs services apply`.

## Backup
The container (or the app folder in the container `docker`) is in the nightly backup, with a safe copy of the databases. The image is `droppedneedle/droppedneedle`.

Not tested on hardware yet.
