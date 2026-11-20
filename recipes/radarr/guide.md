# Radarr: films on autopilot

Set up Radarr so that a film you add is searched, sent to SABnzbd, renamed and filed in your Jellyfin library.

## Before you start
- The share `media`, created by the `jellyfin` recipe, and the overview of the film apps: [Films and series on autopilot](jellyfin.md).
- The downloader and the indexers: [SABnzbd](sabnzbd.md) and [Prowlarr](prowlarr.md), best installed first.
- What you download is your decision and your responsibility: the recipe installs the tool only.

## Set up Radarr
```bash
sudo hs recipe radarr
```

The recipe asks where it runs (own container `radarr` or the container `docker`, see [the overview](jellyfin.md)) and the share name. It mounts the share `media` read-write at `/media`, the same path SABnzbd uses, and prints the address of the page (port 7878). Open it and create a login straight away (method Forms). This is an admin page for the home network: never give it a public route.

### Docker mode
In `docker` mode the compose file and the settings are in `recipes/radarr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the settings in `recipes/radarr/config`). There is no container `radarr`: look at the app with:

```bash
sudo hs ct docker exec docker logs radarr --tail 50
```

There is no nightly duplicate cleanup in `docker` mode (nothing is put into the container `docker` for it); use the `lxc` mode if you want it. The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Connect SABnzbd and Prowlarr
1. Add the root folder under **Settings > Media Management**: `/media/movies`. Keep **Use Hardlinks instead of Copy** on and switch **Rename** on.
2. Add the download client under **Settings > Download Clients > SABnzbd**: the address of `sabnzbd`, its port, the API key from **Config > General** in SABnzbd, category `movies`.
3. Run the recipe once more. It then sets the recycling bin (`/media/downloads/recycle`, emptied after 7 days) and "remove completed" through the app's API; it changes nothing else.

```bash
sudo hs recipe radarr
```

4. In Prowlarr, add Radarr under **Settings > Apps** with `http://<radarr>:7878` and its API key (**Settings > General**), so your indexers arrive here.

Test with one film: add it with **Search on add**. SABnzbd shows the download, then it appears in `/media/movies`.

## Connect Jellyfin
Add the Jellyfin connection by hand (**Settings > Connect > Emby / Jellyfin**, port 8096, an API key from Jellyfin's dashboard): it needs a Jellyfin login, so the recipe cannot do it.

## Duplicate files
A nightly job in the container `radarr` (03:30, asked on first setup) announces the lower resolution of a film with two files in one folder and deletes it after a grace period (14 days by default). `touch .keep-both` in the film's folder vetoes it. Preview:

```bash
sudo hs ct radarr exec python3 /usr/local/lib/hs/hs-arr-dedupe.py --dry-run
```

## Quality profiles
The quality profiles of the TRaSH guides (German ones included) come from the recipe `configarr`, which syncs them every night from your own git repository into Radarr ([its guide](configarr.md)). This recipe does not install anything for it.

An old `recyclarr` folder (`/opt/radarr/recyclarr` in the container, or `recipes/radarr/recyclarr` in the share apps) is not used any more. You can delete it once the profiles are in your repository.

## Coming from the recipe arr
Earlier, one recipe `arr` ran all these apps in one container `arr`. Its settings are not moved over: export them and import them into the new containers.

1. In each app of the old container, make a backup: **System > Backup > Backup Now**, then download the file (Bazarr: **System > Backups**; Maintainerr: export your rules).
2. Install the new recipes (see [the overview](jellyfin.md)). Each app's service (`radarr`, `sonarr` ...) now points at the new container.
3. In each new app, restore the file: **System > Backup > Restore Backup** (Maintainerr: import the rules). The app restarts with your settings. The API keys come with the backup, so Prowlarr, Seerr and Bazarr keep working once their addresses point at the new containers (the old ones all pointed at `arr`).
4. Run `sudo hs recipe radarr` and `sudo hs recipe sonarr` once more, then remove the old container with `sudo hs ct arr remove`. Your films are not touched.

## Check that it worked
- `hs services list` shows Radarr with its container and port.
- `sudo hs recipe radarr --check` says what a new run would change.
- A film added in Radarr lands in `/media/movies` and shows up in Jellyfin after a library scan.

## Update and remove
- Update: run the recipe again (`sudo hs recipe radarr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct radarr remove` asks you to type the container's name and deletes the container with its settings and databases. The share `media` and your files are not touched. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p radarr down` in `/shares/apps/recipes/radarr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/radarr && docker compose -p radarr down'
```

This stops and removes the app's container; the settings and databases in the same folder stay until you delete that folder yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Download does not start | Provider not reachable, or the client is not set up | SABnzbd **Status**; Radarr **System > Status** warnings |
| Finished download stays in `downloads` | Radarr and SABnzbd do not see `/media` the same way | **Activity > Queue** shows the import error |
| Hard link warning at setup | The storage does not allow links between folders of the share | Imports will copy; fix the share's storage |
| "All indexers are unavailable", test is green | The indexer's daily limit is used up and the app paused it | Set **Query Limit** and **Grab Limit** on the indexer in Prowlarr; restart with `sudo hs ct radarr exec docker restart radarr` |
| Search finds nothing though the indexer has it | Releases carry another title than the one Radarr searches | Search in Prowlarr with both titles |
| Logs | | `sudo hs ct radarr logs 100` (docker mode: the logs command above) |

## Next
- [Series: Sonarr](sonarr.md)
- [Indexers: Prowlarr](prowlarr.md)
- [Films and series on autopilot](jellyfin.md)
