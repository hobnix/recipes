# Films and series on autopilot

Set up Radarr, Sonarr, Lidarr, Prowlarr and Bazarr so that a request becomes a file in your Jellyfin library, with the downloader, the request page and the nightly conversion that go with it.

## Before you start
- A running server with the share `media` (created by the `jellyfin` recipe). All containers below see it at the same path, `/media`: a finished download is moved into the library by a hard link, with no copy and no second use of disk space. The recipes try the hard link when they set up and warn when it does not work.
- A Usenet provider and one indexer (accounts you pay for yourself). Provider settings: SSL, port 563, 20 to 30 connections. A VPN is not needed for Usenet.
- Not a recipe task: what you download is your decision and your responsibility. The recipes install tools only.

## How the pieces fit

| Recipe | Container | Job |
| --- | --- | --- |
| `arr` | `arr` | Radarr (films, port 7878), Sonarr (series, 8989), Lidarr (music, 8686), Prowlarr (indexers, 9696), Bazarr (subtitles, 6767), Maintainerr (clean-up rules, 6246), Recyclarr (quality profiles, run by hand) |
| `sabnzbd` | `sabnzbd` | Downloads from Usenet and unpacks into `/media/downloads/usenet/complete` |
| `qbittorrent` | `qbittorrent` | Torrents, only through a VPN ([its guide](qbittorrent.md)) |
| `seerr` | `seerr` | The page where people request films and series |
| `tdarr` | `tdarr` | Converts audio at night so Jellyfin starts films at once ([its guide](tdarr.md)) |
| `jellyfin` | `jellyfin` | Shows the library; creates the share `media` |

Radarr, Sonarr, Prowlarr, Bazarr and SABnzbd do not care which media server you use.

## Set it up
Run the recipes in this order:

```bash
sudo hs recipe sabnzbd
```

```bash
sudo hs recipe arr
```

```bash
sudo hs recipe seerr
```

Each recipe prints the address of its web page at the end. These pages are admin pages for the home network: never give them a public route. Radarr, Sonarr and Prowlarr ask you to create a login on first open (method Forms); do that straight away.

## Connect SABnzbd
Open SABnzbd. The first-run wizard asks for your provider: server, port 563, SSL, user, password, connections. Press **Test Server**.

The recipe already set the folders (finished downloads in `/media/downloads/usenet/complete`, unfinished ones in `/var/tmp/sab-incomplete` inside the container, on the SSD). Check them under **Config > Folders**. Note the **API Key** under **Config > General**. The categories `movies` and `tv` exist already.

## Connect Radarr, Sonarr and Prowlarr
1. In Radarr and Sonarr, add the root folder under **Settings > Media Management**: `/media/movies` and `/media/series` (Lidarr: `/media/music`, category `audio`). Keep **Use Hardlinks instead of Copy** on and switch **Rename** on.
2. In Radarr and Sonarr, add the download client under **Settings > Download Clients > SABnzbd**: the container's address, its port, the API key, category `movies` (Radarr) or `tv` (Sonarr).
3. Run the recipe once more. It then sets the recycling bin (`/media/downloads/recycle`, emptied after 7 days) and "remove completed" through the apps' APIs; it changes nothing else.

```bash
sudo hs recipe arr
```

4. In Prowlarr, add your indexer (**Indexers > Add Indexer**), then add Radarr, Sonarr and Lidarr under **Settings > Apps** with `http://<address of arr>:<port>` and each app's API key (**Settings > General**).
5. Add the Jellyfin connection in Radarr and Sonarr by hand (**Settings > Connect > Emby / Jellyfin**, port 8096, an API key from Jellyfin's dashboard): it needs a Jellyfin login, so the recipe cannot do it.

Test with one film: add it in Radarr with **Search on add**. SABnzbd shows the download, then the film appears in `/media/movies/<Name (Year)>/`.

## Quality profiles with Recyclarr
Recyclarr copies the quality profiles of the TRaSH guides into Radarr and Sonarr (the guides have profiles for several languages, including German ones that prefer releases with German audio). It does not run all the time. List the templates (their names change):

```bash
sudo hs ct arr exec bash -c 'cd /opt/arr && docker compose --profile tools run --rm recyclarr config list templates'
```

Create one file per app from a template, for example:

```bash
sudo hs ct arr exec bash -c 'cd /opt/arr && docker compose --profile tools run --rm recyclarr config create -t radarr-german-hd-bluray-web'
```

Edit the files in `/opt/arr/recyclarr/configs/` inside the container: set `base_url` to `http://<address of arr>:7878` (Sonarr: `:8989`; the name `radarr` is not reachable from the Recyclarr container) and the app's API key. Keep one file per app: Recyclarr stops with "Split Instances" when two files use the same address. Several profiles of one app go into the same file as several `quality_profiles` entries.

```bash
sudo hs ct arr exec bash -c 'cd /opt/arr && docker compose --profile tools run --rm recyclarr sync'
```

The profiles then appear under **Settings > Profiles**. Use an HD profile for most things; UHD and Remux files are 30 GB and more each.

## Subtitles, requests and clean-up
- **Bazarr:** under **Settings > Languages** create a language profile; under **Settings > Providers** add a provider (an account is needed); under **Settings > Radarr** and **Sonarr** enter address and API key. No path mapping is needed because `/media` is the same everywhere.
- **Seerr:** sign in with your Jellyfin account in the first-run wizard, then add Radarr (`:7878`, root folder `/media/movies`) and Sonarr (`:8989`, `/media/series`) under **Settings > Services**. It is the only page of this group that could get a public route; finish the setup first, because the wizard is open to whoever gets there first. Put a login in front of it (see the [Authentik guide](authentik.md)).
Not tested on hardware yet: Seerr and the Maintainerr rules.
- **Maintainerr** deletes by rules you write and starts with none. Create a rule as a collection first, look at what it would hit, and only then switch deleting on.
- **Duplicate files:** a nightly job (03:30, asked on first setup) announces the lower resolution of a film with two files in one folder and deletes it after a grace period (14 days by default). `touch .keep-both` in the film's folder vetoes it. Preview:

```bash
sudo hs ct arr exec python3 /usr/local/lib/hs/hs-arr-dedupe.py --dry-run
```

## Notifications and backup
- The recipe `arr` creates its own ntfy topic and prints it (also in `/var/lib/hs/media-ntfy`). Subscribe in the ntfy app, then add it in Radarr and Sonarr under **Settings > Connect > ntfy**. It is separate from the topic of the server's alarms on purpose.
- To also post cards into a Matrix room, run `sudo hs recipe matrix-hook` (needs the `synapse` recipe) and add the webhook address it prints under **Settings > Connect > Webhook**.
- The containers `arr`, `sabnzbd` and `seerr` are in the nightly backup, with a database dump before each run. The films themselves are backed up with `hs backup media on`.

## Check that it worked
- `hs ext arr status` lists each app with its port and state (the command exists once the recipe has run).
- `sudo hs recipe arr --check` says what a new run would change.
- A film added in Radarr lands in `/media/movies` and shows up in Jellyfin after a library scan.

## Update and remove
- Update: run the recipe again (`sudo hs recipe arr`, `sabnzbd`, `seerr`); it fetches newer images and restarts. Your settings stay.
- Remove: `sudo hs ct arr remove` asks you to type the container's name and deletes the container with its settings and databases. The share `media` and your films are not touched. Restore from the backup with `hs backup`.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Download does not start | Provider not reachable, or the client is not set up | SABnzbd **Status**; Radarr/Sonarr **System > Status** warnings |
| Finished film stays in `downloads` | Radarr and SABnzbd do not see `/media` the same way | Radarr **Activity > Queue** shows the import error |
| Hard link warning at setup | The storage does not allow links between folders of the share | Imports will copy; fix the share's storage |
| "All indexers are unavailable", test is green | The indexer's daily limit is used up and the apps paused it | Set **Query Limit** and **Grab Limit** on the indexer in Prowlarr; restart with `sudo hs ct arr exec docker restart sonarr radarr` |
| Search finds nothing though the indexer has it | Releases carry another title than the one Sonarr searches | Search in Prowlarr with both titles |
| Logs | | `sudo hs ct arr logs 100` |

## Next
- [Converting films with Tdarr](tdarr.md)
- [Torrents through a VPN](qbittorrent.md)
