# Jellyfin, and your own discs

Set up Jellyfin for films, series and music on the server, then turn your DVDs and Blu-rays into files it can play.

## Before you start
- A running server with bulk storage ([Storage and disks](storage-and-disks.md)).
- For ripping: a Windows PC with a disc drive (a DVD drive reads DVDs; Blu-rays need a Blu-ray drive, external USB ones from about 60 EUR are fine). 4K Ultra HD discs need a LibreDrive-capable drive; the list is in the MakeMKV forum.
- Free space on the PC: about 4 to 8 GB per DVD, 20 to 40 GB per Blu-ray, 50 to 90 GB per 4K disc.

## Set up Jellyfin

```bash
sudo hs recipe jellyfin
```

The recipe creates the container `jellyfin` and installs Jellyfin from its package source. It asks for the **share name** (default `media`, under `/bulk/shares`) and creates it with the folders `movies`, `series`, `music`, `anime/series` and `anime/movies`. The share is mounted read-only at `/media`: Jellyfin only reads, so it can never delete or change a film. It also passes a graphics card into the container (NVIDIA, else the processor's Intel or AMD chip) so videos can be converted for devices that need it without loading the CPU, and it asks once about the optional dark "Abyss" theme (default no).

Jellyfin's own data (users, posters, what was watched) is on the SSD pool inside the container. Open the address the recipe prints (port 8096 unless you chose another); the first visit sets up the admin account. Add libraries for `/media/movies`, `/media/series` and `/media/music`.

## Films and series on autopilot
Jellyfin creates the share `media` that every film app uses. Each app below is a recipe of its own; install only the ones you want. All of them see the share at the same path, `/media`: a finished download moves into the library by a hard link, with no copy. The recipes try the hard link when they set up and warn when it does not work.

| Recipe | Port | Job |
| --- | --- | --- |
| `radarr` | 7878 | Films, with a nightly duplicate cleanup ([guide](radarr.md)) |
| `sonarr` | 8989 | Series ([guide](sonarr.md)) |
| `lidarr` | 8686 | Music ([guide](lidarr.md)) |
| `prowlarr` | 9696 | Holds your indexers and hands them to Radarr, Sonarr and Lidarr ([guide](prowlarr.md)) |
| `bazarr` | 6767 | Subtitles for what Radarr and Sonarr hold ([guide](bazarr.md)) |
| `maintainerr` | 6246 | Clean-up rules for unwatched media ([guide](maintainerr.md)) |
| `sabnzbd` | 8080 | Downloads from Usenet into `/media/downloads/usenet/complete` ([guide](sabnzbd.md)) |
| `configarr` | | Syncs quality profiles from your git repository into Radarr and Sonarr every night ([guide](configarr.md)) |
| `qbittorrent` | | Torrents, only through a VPN ([guide](qbittorrent.md)) |
| `seerr` | | The page where people request films and series ([guide](seerr.md)) |
| `tdarr` | | Converts audio at night so Jellyfin starts films at once ([guide](tdarr.md)) |

You need a Usenet provider and one indexer (accounts you pay for yourself). What you download is your decision and your responsibility: the recipes install tools only. Run the recipes in this order (leave out what you do not need), one command at a time:

```bash
sudo hs recipe sabnzbd
```

```bash
sudo hs recipe prowlarr
```

```bash
sudo hs recipe radarr
```

```bash
sudo hs recipe sonarr
```

Then, if you want them, `lidarr`, `bazarr`, `maintainerr` and `seerr`. Each recipe prints the address of its web page at the end. These pages are admin pages for the home network: never give them a public route. Radarr, Sonarr, Lidarr and Prowlarr ask you to create a login on first open (method Forms); do that straight away.

### Where the apps run: own container or Docker
`radarr`, `sonarr`, `lidarr`, `prowlarr`, `bazarr`, `maintainerr`, `seerr`, `sabnzbd` and `jellyfin` can run in one of two places; the recipe asks "Where it runs" (`RUNS`, `lxc` or `docker`):
- `lxc`: a container of its own with the app's name and Docker inside. An app that is installed this way stays there.
- `docker`: the app is a compose project inside the one container `docker` (turned on with `sudo hs docker enable`, see [Docker](containers-and-apps.md)), in the share `apps`. A new install proposes `docker` when Docker is on.

What is different in the `docker` mode:
- All film apps in `docker` share one user `media`, and the share `media` is mounted once into the container `docker` at `/media`. Mounting restarts `docker` and every app in it, so when other apps already run there the recipe stops and prints the exact `hs docker mount ...` command. Run it when it suits you, then run the recipe again.
- The ports are fixed, so a second copy of a recipe (`--name`) in `docker` mode stops at the port check. Use the `lxc` mode for a second copy.
- Moving an app between the modes is not automated: back up in the app (**System > Backup**), install the recipe in the other mode, restore there. Not tested on hardware yet: the `docker` mode of Seerr, SABnzbd and Jellyfin.

### Notifications and backup
- The film apps share one ntfy topic of their own; `radarr`, `sonarr` and `lidarr` print it (also in `/var/lib/hs/media-ntfy`). Subscribe in the ntfy app, then add it in each app under **Settings > Connect > ntfy**. It is separate from the topic of the server's alarms on purpose.
- To also post cards into a Matrix room, run `sudo hs recipe matrix-hook` (needs the `synapse` recipe) and add the webhook address it prints under **Settings > Connect > Webhook**.
- Every container of this group is in the nightly backup, with a database dump before each run. The films themselves are backed up with `hs backup media on`.

### Local names with the gateway
Each app is a service of its own in `hs services`. With the extension `gateway` on, every app gets a name on the home network, such as `http://radarr.<local domain>`. `hs gateway check` shows the local domain and tests the wildcard DNS record `*.<local domain>`, which your router or DNS server needs once. Run the app's recipe again after turning the gateway on. Not tested on hardware yet.

## Show the running streams on the dashboard
The Jellyfin tile can show how many streams play right now. Jellyfin only tells this to a program with an API key, and a key can only be made by you: in Jellyfin open **Dashboard > API Keys**, add a key (any name, for example `hobnix`), then run:

```bash
sudo hs services key jellyfin
```

The command asks for the key (hidden, it is not shown and not kept in the shell history), stores it in the vault and checks that Jellyfin answers. Until a key is set the tile shows no number. Not tested on hardware yet.

## Rip a disc with MakeMKV
MakeMKV reads a disc and saves film and sound unchanged as an `.mkv` file. Nothing is re-encoded; the quality is that of the disc. MakeMKV runs on the Windows PC (that is where the drive is), the server only receives the finished files through the share.

Cost: MakeMKV is free while in beta, but its registration key is valid only about a month and is posted in the MakeMKV forum. A licence (a one-time payment of about 50 EUR) covers all 1.x versions and pays off after a few discs.

1. Start MakeMKV, insert the disc, click the large drive icon. After the disc structure is read (about a minute for a Blu-ray) the list of titles appears.
2. Find the main title: the longest one (1:30 to 2:30 hours for a film). Blu-rays have many similar playlists: take the longest, and when several are close the one with the largest file.
3. Choose tracks: keep the video; audio in your language and the original language (drop commentary tracks; of two versions in one language take the better format: TrueHD or DTS-HD before AC3 or DTS); subtitles in your language, "forced" subtitles (foreign speech only) and English.
4. Choose an output folder on a local SSD, for example `D:\rips\Film Name (Year)`, and press **Make MKV**. A DVD takes 10 to 20 minutes, a Blu-ray 30 to 60. Ripping to a local disk first is much faster than writing over the network.

Tips:
- Under **File > Preferences > Video** set the minimum title length to 1200 seconds: menus, trailers and ads are then not listed.
- A series DVD has one title per episode: tick them all. Read errors are almost always scratches or dirt: wipe the disc and try again.
- MakeMKV bypasses the copy protection automatically. In some countries this is illegal even for private copies of your own discs (in Germany, section 95a of the copyright act). It is your decision and responsibility: copy only discs you own and do not pass the files on.

## Name the files and put them on the server
Jellyfin recognises films only when folder and file are named like the film database:

```
\\<server>\media\movies\Film Name (1972)\Film Name (1972).mkv
\\<server>\media\series\Show Name (1989)\Season 01\Show Name S01E01.mkv
```

- The year in brackets matters for films; it separates films with the same name.
- Several versions of one film: `Film Name (1972) - Director's Cut.mkv` in the same folder.
- Series: `S01E01`, `S01E02` and so on, one folder `Season 01` per season.

The share `media` is read-only for Jellyfin but writable for you over the network (see [Users and shares](users-and-shares.md)). Copy the finished folder, then scan: **Dashboard > Libraries > Scan** (Jellyfin also scans by itself). A film that does not match is usually named wrongly: rename it and scan again.

## Afterwards: Tdarr
The [Tdarr plugin](tdarr.md) adds an AC3 audio track to films that have only TrueHD or DTS sound, so TVs and browsers play them. A DVD's picture is MPEG-2; the plugin turns it into H.264 (smaller, no visible difference), which takes a few minutes to half an hour per film. Blu-ray pictures stay unchanged.

You can skip: Handbrake (MakeMKV plus Tdarr replace it; re-encoding a 30 GB Blu-ray to 8 to 10 GB with H.265 saves space but costs quality and time, and is not needed) and ISO images (the `.mkv` is enough to play; keep the discs as your backup).

## Run it in Docker
Jellyfin can run as an app in the container `docker` too (`RUNS=docker`; see the overview above). The compose file is in `recipes/jellyfin` in the share `apps` (mounted at `/shares/apps` in `docker`; users and posters in `recipes/jellyfin/config`). There is no container `jellyfin`; Jellyfin reads `/media` read-only. The Abyss theme is only set up in the `lxc` mode; in Docker add it under **Dashboard > Branding**. The page is on port 8096 of the container `docker`. The recipe never adds a graphics card to `docker`. It uses one only when `docker` has one already (a render device or the NVIDIA runtime); otherwise it warns that Jellyfin converts videos on the CPU. For hardware transcoding use the `lxc` mode. Not tested on hardware yet: Jellyfin in Docker, and its hardware transcoding.

```bash
sudo hs ct docker exec docker logs jellyfin --tail 50
```

Remove it (the settings stay in the folder):

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/jellyfin && docker compose -p jellyfin down'
```

## Check that it worked
- The library shows the film with poster and description, and it plays on the TV or in the browser.
- `hs ct list` shows the container `jellyfin` running.

## Update and remove
- Update: `sudo hs ct jellyfin update` makes a snapshot, then updates the software inside. The recipe `sudo hs recipe jellyfin` can be run again at any time.
- Remove: `sudo hs ct jellyfin remove` asks you to type the name and deletes the container with its users and watch history. The share `media` and your films stay.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Film shows the wrong title or none | Folder or file name does not match the film | Rename as above, scan again |
| Disc will not read | Scratches, dirt, or a 4K disc without a LibreDrive drive | Clean it; try another drive |
| A film starts only after many seconds | The sound has to be converted at every start | Let [Tdarr](tdarr.md) add an AC3 track |
| Jellyfin cannot see new files | The library has not been scanned | **Dashboard > Libraries > Scan** |

## Next
- [Radarr: films on autopilot](radarr.md)
- [Sonarr: series on autopilot](sonarr.md)
- [Convert films for Jellyfin](tdarr.md)
