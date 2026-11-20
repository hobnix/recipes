# Bazarr: subtitles for your library

Set up Bazarr so that it fetches subtitles for the films and series that Radarr and Sonarr hold and puts them next to the video files.

## Before you start
- [Radarr](radarr.md) and [Sonarr](sonarr.md) installed, and the share `media` ([Films and series on autopilot](jellyfin.md)).
- An account at a subtitle provider (Bazarr cannot do without one).

## Set up Bazarr
```bash
sudo hs recipe bazarr
```

The recipe asks where it runs (own container or the container `docker`, see [the overview](jellyfin.md)) and the share name. It mounts the share `media` read-write at `/media` and prints the address of the page (port 6767). This is an admin page for the home network: never give it a public route.

### Docker mode
In `docker` mode the compose file is in `recipes/bazarr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the settings in `recipes/bazarr/config`). There is no container `bazarr`: look at the app with:

```bash
sudo hs ct docker exec docker logs bazarr --tail 50
```

The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Connect it
1. Under **Settings > Languages** create a language profile.
2. Under **Settings > Providers** add a provider.
3. Under **Settings > Radarr** and **Settings > Sonarr** enter address and API key (`http://<radarr>:7878`, `http://<sonarr>:8989`).

No path mapping is needed because `/media` is the same everywhere. Bazarr does not serve Lidarr.

## Check that it worked
- `hs services list` shows Bazarr with its container and port.
- Under **Movies** or **Series** an entry shows the subtitle languages it wants. A subtitle file lands next to the video.

## Update and remove
- Update: run the recipe again (`sudo hs recipe bazarr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct bazarr remove` asks you to type the container's name and deletes the container with its settings and databases. The share `media` and your files are not touched. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p bazarr down` in `/shares/apps/recipes/bazarr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/bazarr && docker compose -p bazarr down'
```

This stops and removes the app's container; the settings stay in the same folder until you delete it yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| No subtitles are found | No provider, or no language profile on the film | Check the provider under **Settings > Providers** and assign the profile |
| Bazarr cannot reach Radarr or Sonarr | Wrong address or API key | Test the connection under **Settings > Radarr** / **Sonarr** |
| Logs | | `sudo hs ct bazarr logs 100` (docker mode: the logs command above) |

## Next
- [Films: Radarr](radarr.md)
- [Series: Sonarr](sonarr.md)
- [Films and series on autopilot](jellyfin.md)
