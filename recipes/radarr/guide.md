# Films and series on autopilot

Set up Radarr, Sonarr, Lidarr, Prowlarr and Bazarr so that a request becomes a file in your Jellyfin library, with the downloader, the request page and the nightly conversion that go with it.

## Before you start
- A running server with the share `media` (created by the `jellyfin` recipe). All containers below see it at the same path, `/media`: a finished download is moved into the library by a hard link, with no copy and no second use of disk space. The recipes try the hard link when they set up and warn when it does not work.
- A Usenet provider and one indexer (accounts you pay for yourself). Provider settings: SSL, port 563, 20 to 30 connections. A VPN is not needed for Usenet.
- Not a recipe task: what you download is your decision and your responsibility. The recipes install tools only.

## How the pieces fit
Each app is a recipe of its own, in a container of the same name. Install only the ones you want.

| Recipe | Port | Job |
| --- | --- | --- |
| `radarr` | 7878 | Films; also the nightly duplicate cleanup and Recyclarr (quality profiles, run by hand) |
| `sonarr` | 8989 | Series; also Recyclarr |
| `lidarr` | 8686 | Music |
| `prowlarr` | 9696 | Holds your indexers and hands them to Radarr, Sonarr and Lidarr |
| `bazarr` | 6767 | Subtitles for what Radarr and Sonarr hold |
| `maintainerr` | 6246 | Clean-up rules for unwatched media |
| `sabnzbd` | 8080 | Downloads from Usenet and unpacks into `/media/downloads/usenet/complete` |
| `qbittorrent` | | Torrents, only through a VPN ([its guide](qbittorrent.md)) |
| `seerr` | | The page where people request films and series |
| `tdarr` | | Converts audio at night so Jellyfin starts films at once ([its guide](tdarr.md)) |
| `jellyfin` | 8096 | Shows the library; creates the share `media` |

Radarr, Sonarr, Prowlarr, Bazarr and SABnzbd do not care which media server you use.

## Set it up
Run the recipes in this order (leave out what you do not need):

```bash
sudo hs recipe sabnzbd
sudo hs recipe prowlarr
sudo hs recipe radarr
sudo hs recipe sonarr
```

Then, if you want them, `lidarr`, `bazarr`, `maintainerr` and `seerr`. Each recipe prints the address of its web page at the end; `<radarr>` below means the address of the container `radarr`, and so on. These pages are admin pages for the home network: never give them a public route. Radarr, Sonarr, Lidarr and Prowlarr ask you to create a login on first open (method Forms); do that straight away.

## Connect SABnzbd
Open SABnzbd. The first-run wizard asks for your provider: server, port 563, SSL, user, password, connections. Press **Test Server**.

The recipe already set the folders (finished downloads in `/media/downloads/usenet/complete`, unfinished ones in `/var/tmp/sab-incomplete` inside the container, on the SSD). Check them under **Config > Folders**. Note the **API Key** under **Config > General**. The categories `movies` and `tv` exist already.

## Connect Radarr, Sonarr and Prowlarr
1. In Radarr and Sonarr, add the root folder under **Settings > Media Management**: `/media/movies` and `/media/series` (Lidarr: `/media/music`, category `audio`). Keep **Use Hardlinks instead of Copy** on and switch **Rename** on.
2. In Radarr and Sonarr, add the download client under **Settings > Download Clients > SABnzbd**: the address of `sabnzbd`, its port, the API key, category `movies` (Radarr) or `tv` (Sonarr).
3. Run both recipes once more. They then set the recycling bin (`/media/downloads/recycle`, emptied after 7 days) and "remove completed" through the apps' APIs; they change nothing else.

```bash
sudo hs recipe radarr
sudo hs recipe sonarr
```

4. In Prowlarr, add your indexer (**Indexers > Add Indexer**), then add Radarr, Sonarr and Lidarr under **Settings > Apps** with `http://<radarr>:7878`, `http://<sonarr>:8989`, `http://<lidarr>:8686` and each app's API key (**Settings > General**). Prowlarr Server is `http://<prowlarr>:9696`.
5. Add the Jellyfin connection in Radarr and Sonarr by hand (**Settings > Connect > Emby / Jellyfin**, port 8096, an API key from Jellyfin's dashboard): it needs a Jellyfin login, so the recipe cannot do it.

Test with one film: add it in Radarr with **Search on add**. SABnzbd shows the download, then the film appears in `/media/movies/<Name (Year)>/`.

## Quality profiles with Recyclarr
Recyclarr copies the quality profiles of the TRaSH guides into Radarr and Sonarr (the guides have profiles for several languages, including German ones that prefer releases with German audio). It does not run all the time; the containers `radarr` and `sonarr` each have their own copy. List the templates (their names change):

```bash
sudo hs ct radarr exec bash -c 'cd /opt/radarr && docker compose --profile tools run --rm recyclarr config list templates'
```

Create the file from a template, for example:

```bash
sudo hs ct radarr exec bash -c 'cd /opt/radarr && docker compose --profile tools run --rm recyclarr config create -t radarr-german-hd-bluray-web'
```

Edit it in `/opt/radarr/recyclarr/configs/` inside the container: set `base_url` to `http://<radarr>:7878` and Radarr's API key. Several profiles go into the same file as several `quality_profiles` entries. For Sonarr, do the same in the container `sonarr` (`/opt/sonarr`, a `sonarr-...` template, `http://<sonarr>:8989`).

```bash
sudo hs ct radarr exec bash -c 'cd /opt/radarr && docker compose --profile tools run --rm recyclarr sync'
```

The profiles then appear under **Settings > Profiles**. Use an HD profile for most things; UHD and Remux files are 30 GB and more each.

## Subtitles, requests and clean-up
- **Bazarr:** under **Settings > Languages** create a language profile; under **Settings > Providers** add a provider (an account is needed); under **Settings > Radarr** and **Sonarr** enter address and API key. No path mapping is needed because `/media` is the same everywhere.
- **Seerr:** sign in with your Jellyfin account in the first-run wizard, then add Radarr (`http://<radarr>:7878`, root folder `/media/movies`) and Sonarr (`http://<sonarr>:8989`, `/media/series`) under **Settings > Services**. It is the only page of this group that could get a public route; finish the setup first, because the wizard is open to whoever gets there first. Put a login in front of it (see the [Authentik guide](authentik.md)).
Not tested on hardware yet: Seerr and the Maintainerr rules.
- **Maintainerr** deletes by rules you write and starts with none. Connect Jellyfin, Radarr and Sonarr under its **Settings**, create a rule as a collection first, look at what it would hit, and only then switch deleting on.
- **Duplicate files:** a nightly job in the container `radarr` (03:30, asked on first setup) announces the lower resolution of a film with two files in one folder and deletes it after a grace period (14 days by default). `touch .keep-both` in the film's folder vetoes it. Preview:

```bash
sudo hs ct radarr exec python3 /usr/local/lib/hs/hs-arr-dedupe.py --dry-run
```

## Notifications and backup
- The film apps share one ntfy topic of their own; `radarr`, `sonarr` and `lidarr` print it (also in `/var/lib/hs/media-ntfy`). Subscribe in the ntfy app, then add it in each app under **Settings > Connect > ntfy**. It is separate from the topic of the server's alarms on purpose.
- To also post cards into a Matrix room, run `sudo hs recipe matrix-hook` (needs the `synapse` recipe) and add the webhook address it prints under **Settings > Connect > Webhook**.
- Every container of this group is in the nightly backup, with a database dump before each run. The films themselves are backed up with `hs backup media on`.

## Local names with the gateway
Each app is a service of its own in `hs services` (`radarr`, `sonarr`, `lidarr`, `prowlarr`, `bazarr`, `maintainerr`). With the extension `gateway` on, every app gets a name on the home network: `http://sonarr.<local domain>`, `http://radarr.<local domain>` and so on. `hs gateway check` shows the local domain and tests the wildcard DNS record `*.<local domain>`, which your router or DNS server needs once. The apps are admin pages that manage downloads: never public. Their dashboard tiles come from the services (the question "Show on the dashboard?" is asked per app). Run the app's recipe again after turning the gateway on. Not tested on hardware yet.

## Coming from the recipe arr
Earlier, one recipe `arr` ran all these apps in one container `arr`. Its settings are not moved over: export them and import them into the new containers.

1. In each app of the old container, make a backup: **System > Backup > Backup Now**, then download the file (Bazarr: **System > Backups**; Maintainerr: export your rules).
2. Install the new recipes as above. Each app's service (`radarr`, `sonarr` ...) now points at the new container.
3. In each new app, restore the file: **System > Backup > Restore Backup** (Maintainerr: import the rules). The app restarts with your settings. The API keys come with the backup, so Prowlarr, Seerr and Bazarr keep working once their addresses point at the new containers (the old ones all pointed at `arr`).
4. Run `sudo hs recipe radarr` and `sudo hs recipe sonarr` once more, then remove the old container with `sudo hs ct arr remove`. Your films are not touched.

## Check that it worked
- `hs services list` shows each app with its container and port.
- `sudo hs recipe radarr --check` says what a new run would change (the same for the other recipes).
- A film added in Radarr lands in `/media/movies` and shows up in Jellyfin after a library scan.

## Update and remove
- Update: run the recipe again (`sudo hs recipe radarr`, `sonarr`, `sabnzbd`, ...); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct radarr remove` asks you to type the container's name and deletes the container with its settings and databases (the same for the others). The share `media` and your films are not touched. Restore from the backup with `hs backup`.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Download does not start | Provider not reachable, or the client is not set up | SABnzbd **Status**; Radarr/Sonarr **System > Status** warnings |
| Finished film stays in `downloads` | Radarr and SABnzbd do not see `/media` the same way | Radarr **Activity > Queue** shows the import error |
| Hard link warning at setup | The storage does not allow links between folders of the share | Imports will copy; fix the share's storage |
| "All indexers are unavailable", test is green | The indexer's daily limit is used up and the apps paused it | Set **Query Limit** and **Grab Limit** on the indexer in Prowlarr; restart with `sudo hs ct sonarr exec docker restart sonarr` (Radarr: the same with `radarr`) |
| Search finds nothing though the indexer has it | Releases carry another title than the one Sonarr searches | Search in Prowlarr with both titles |
| Logs | | `sudo hs ct radarr logs 100` (the same for the others) |

## Next
- [Converting films with Tdarr](tdarr.md)
- [Torrents through a VPN](qbittorrent.md)
