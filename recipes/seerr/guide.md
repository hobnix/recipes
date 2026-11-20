# Seerr: a page for film and series requests

Set up Seerr so that family and friends can ask for films and series; a request goes to Radarr or Sonarr.

## Before you start
- [Jellyfin](jellyfin.md) with a library, and [Radarr](radarr.md) and [Sonarr](sonarr.md) installed ([Films and series on autopilot](jellyfin.md)).

## Set up Seerr
```bash
sudo hs recipe seerr
```

The recipe creates the container `seerr` and prints the address of the page (port 80 unless you chose another). It mounts no share: Seerr never touches a file of the library. The settings are on the SSD pool inside the container, in the nightly backup with a database dump.

**The setup wizard is open to whoever reaches it first.** Finish it before you give the page any public route.

### Docker mode
In `docker` mode the compose file is in `recipes/seerr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the settings in `recipes/seerr/config`). There is no container `seerr`; the page is on port 5055 of the container `docker`. Look at the app with:

```bash
sudo hs ct docker exec docker logs seerr --tail 50
```

The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Run the wizard
1. Sign in with your Jellyfin account. Everybody signs in the same way, so there is no second set of passwords.
2. Add Radarr (`http://<radarr>:7878`, root folder `/media/movies`) and Sonarr (`http://<sonarr>:8989`, root folder `/media/series`) under **Settings > Services**, each with its API key (**Settings > General** in the app).

Not tested on hardware yet: Seerr.

## Let friends reach it
Seerr is the only page of the film apps that could get a public route, and that is your decision. Put a login in front of it (see the [Authentik guide](authentik.md)). The recipe sets no Zoraxy rule.

## Check that it worked
- `hs services list` shows Seerr with its container and port.
- A request made in Seerr appears in Radarr or Sonarr and is searched.

## Update and remove
- Update: run the recipe again (`sudo hs recipe seerr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct seerr remove` asks you to type the container's name and deletes the container with its settings. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p seerr down` in `/shares/apps/recipes/seerr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/seerr && docker compose -p seerr down'
```

This stops and removes the app's container; the settings stay in the same folder until you delete it yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Sign-in fails | Wrong Jellyfin address or account | Use the address of the container `jellyfin` and an account of Jellyfin |
| A request does not reach Radarr or Sonarr | Wrong address, API key or root folder | Test the entry under **Settings > Services** |
| Logs | | `sudo hs ct seerr logs 100` |

## Next
- [Films: Radarr](radarr.md)
- [Series: Sonarr](sonarr.md)
- [Films and series on autopilot](jellyfin.md)
