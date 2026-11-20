# Lidarr: music on autopilot

Set up Lidarr so that an album you add is searched, sent to SABnzbd, renamed and filed in your Jellyfin music library.

## Before you start
- The share `media`, created by the `jellyfin` recipe, and the overview of the film apps: [Films and series on autopilot](jellyfin.md).
- The downloader and the indexers: [SABnzbd](sabnzbd.md) and [Prowlarr](prowlarr.md).

## Set up Lidarr
```bash
sudo hs recipe lidarr
```

The recipe asks where it runs (own container or the container `docker`, see [the overview](jellyfin.md)) and the share name. It mounts the share `media` read-write at `/media`, the same path SABnzbd uses, and prints the address of the page (port 8686). Open it and create a login straight away (method Forms). This is an admin page for the home network: never give it a public route.

### Docker mode
In `docker` mode the compose file is in `recipes/lidarr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the settings in `recipes/lidarr/config`). There is no container `lidarr`: look at the app with:

```bash
sudo hs ct docker exec docker logs lidarr --tail 50
```

The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Connect SABnzbd and Prowlarr
1. Add the root folder under **Settings > Media Management**: `/media/music`. Keep **Use Hardlinks instead of Copy** on and switch **Rename** on.
2. Add the download client under **Settings > Download Clients > SABnzbd**: the address of `sabnzbd`, its port, the API key from **Config > General** in SABnzbd, category `audio`.
3. In Prowlarr, add Lidarr under **Settings > Apps** with `http://<lidarr>:8686` and its API key (**Settings > General**).
4. Run the recipe once more. It then sets the recycling bin (`/media/downloads/recycle`, emptied after 7 days) and "remove completed" through the app's API.

```bash
sudo hs recipe lidarr
```

Test with one album: add it with **Search on add**. SABnzbd shows the download, then it appears in `/media/music`.

## Check that it worked
- `hs services list` shows Lidarr with its container and port.
- `sudo hs recipe lidarr --check` says what a new run would change.
- An album added in Lidarr lands in `/media/music` and shows up in Jellyfin after a library scan.

## Update and remove
- Update: run the recipe again (`sudo hs recipe lidarr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct lidarr remove` asks you to type the container's name and deletes the container with its settings and databases. The share `media` and your files are not touched. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p lidarr down` in `/shares/apps/recipes/lidarr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/lidarr && docker compose -p lidarr down'
```

This stops and removes the app's container; the settings stay in the same folder until you delete it yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Download does not start | Provider not reachable, or the client is not set up | SABnzbd **Status**; Lidarr **System > Status** warnings |
| Finished album stays in `downloads` | Lidarr and SABnzbd do not see `/media` the same way | **Activity > Queue** shows the import error |
| Hard link warning at setup | The storage does not allow links between folders of the share | Imports will copy; fix the share's storage |
| Logs | | `sudo hs ct lidarr logs 100` (docker mode: the logs command above) |

## Next
- [Indexers: Prowlarr](prowlarr.md)
- [Films and series on autopilot](jellyfin.md)
