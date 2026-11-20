# Sonarr: series on autopilot

Set up Sonarr so that a series you add is searched, sent to SABnzbd, renamed and filed in your Jellyfin library.

## Before you start
- The share `media`, created by the `jellyfin` recipe, and the overview of the film apps: [Films and series on autopilot](jellyfin.md).
- The downloader and the indexers: [SABnzbd](sabnzbd.md) and [Prowlarr](prowlarr.md), best installed first.
- What you download is your decision and your responsibility: the recipe installs the tool only.

## Set up Sonarr
```bash
sudo hs recipe sonarr
```

The recipe asks where it runs (own container `sonarr` or the container `docker`, see [the overview](jellyfin.md)) and the share name. It mounts the share `media` read-write at `/media`, the same path SABnzbd uses, and prints the address of the page (port 8989). Open it and create a login straight away (method Forms). This is an admin page for the home network: never give it a public route.

### Docker mode
In `docker` mode the compose file and the settings are in `recipes/sonarr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the settings in `recipes/sonarr/config`). There is no container `sonarr`: look at the app with:

```bash
sudo hs ct docker exec docker logs sonarr --tail 50
```

The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Connect SABnzbd and Prowlarr
1. Add the root folder under **Settings > Media Management**: `/media/series`. Keep **Use Hardlinks instead of Copy** on and switch **Rename** on.
2. Add the download client under **Settings > Download Clients > SABnzbd**: the address of `sabnzbd`, its port, the API key from **Config > General** in SABnzbd, category `tv`.
3. Run the recipe once more. It then sets the recycling bin (`/media/downloads/recycle`, emptied after 7 days) and "remove completed" through the app's API; it changes nothing else.

```bash
sudo hs recipe sonarr
```

4. In Prowlarr, add Sonarr under **Settings > Apps** with `http://<sonarr>:8989` and its API key (**Settings > General**), so your indexers arrive here.

Test with one series: add it with **Search on add**. SABnzbd shows the download, then it appears in `/media/series`.

## Connect Jellyfin
Add the Jellyfin connection by hand (**Settings > Connect > Emby / Jellyfin**, port 8096, an API key from Jellyfin's dashboard): it needs a Jellyfin login, so the recipe cannot do it.

## Quality profiles
The quality profiles of the TRaSH guides (German ones included) come from the recipe `configarr`, which syncs them every night from your own git repository into Sonarr ([its guide](configarr.md)). This recipe does not install anything for it.

An old `recyclarr` folder (`/opt/sonarr/recyclarr` in the container, or `recipes/sonarr/recyclarr` in the share apps) is not used any more. You can delete it once the profiles are in your repository.

## Check that it worked
- `hs services list` shows Sonarr with its container and port.
- `sudo hs recipe sonarr --check` says what a new run would change.
- A series added in Sonarr lands in `/media/series` and shows up in Jellyfin after a library scan.

## Update and remove
- Update: run the recipe again (`sudo hs recipe sonarr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct sonarr remove` asks you to type the container's name and deletes the container with its settings and databases. The share `media` and your files are not touched. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p sonarr down` in `/shares/apps/recipes/sonarr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/sonarr && docker compose -p sonarr down'
```

This stops and removes the app's container; the settings and databases in the same folder stay until you delete that folder yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Download does not start | Provider not reachable, or the client is not set up | SABnzbd **Status**; Sonarr **System > Status** warnings |
| Finished download stays in `downloads` | Sonarr and SABnzbd do not see `/media` the same way | **Activity > Queue** shows the import error |
| Hard link warning at setup | The storage does not allow links between folders of the share | Imports will copy; fix the share's storage |
| "All indexers are unavailable", test is green | The indexer's daily limit is used up and the app paused it | Set **Query Limit** and **Grab Limit** on the indexer in Prowlarr; restart with `sudo hs ct sonarr exec docker restart sonarr` |
| Search finds nothing though the indexer has it | Releases carry another title than the one Sonarr searches | Search in Prowlarr with both titles |
| Logs | | `sudo hs ct sonarr logs 100` (docker mode: the logs command above) |

## Next
- [Films: Radarr](radarr.md)
- [Indexers: Prowlarr](prowlarr.md)
- [Films and series on autopilot](jellyfin.md)
