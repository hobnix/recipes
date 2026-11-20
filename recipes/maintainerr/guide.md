# Maintainerr: clean-up rules for unwatched media

Set up Maintainerr to collect unwatched films and series by rules you write and, only when you switch it on, delete them through Radarr and Sonarr.

## Before you start
- [Jellyfin](jellyfin.md), [Radarr](radarr.md) and [Sonarr](sonarr.md) running ([Films and series on autopilot](jellyfin.md)).
- Time to think about the rules: Maintainerr starts with none and deletes nothing until you say so.

## Set up Maintainerr
```bash
sudo hs recipe maintainerr
```

The recipe asks where it runs (own container or the container `docker`, see [the overview](jellyfin.md)) and prints the address of the page (port 6246). It mounts no share: Maintainerr deletes through Radarr and Sonarr, never by itself. This is an admin page for the home network: never give it a public route.

### Docker mode
In `docker` mode the compose file is in `recipes/maintainerr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the database in `recipes/maintainerr/data`). There is no container `maintainerr`: look at the app with:

```bash
sudo hs ct docker exec docker logs maintainerr --tail 50
```

The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Write a rule
1. Connect Jellyfin, Radarr and Sonarr under **Settings**.
2. Create a rule as a collection first.
3. Look at what the rule would hit.
4. Only then switch deleting on.

Not tested on hardware yet: the Maintainerr rules.

## Check that it worked
- `hs services list` shows Maintainerr with its container and port.
- The collection of a rule lists the films or series you expect, and nothing is deleted yet.

## Update and remove
- Update: run the recipe again (`sudo hs recipe maintainerr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct maintainerr remove` asks you to type the container's name and deletes the container with its settings and databases. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p maintainerr down` in `/shares/apps/recipes/maintainerr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/maintainerr && docker compose -p maintainerr down'
```

This stops and removes the app's container; the settings stay in the same folder until you delete it yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| A rule hits too much | The rule is too wide | Keep deleting off and narrow the rule until the collection is right |
| Maintainerr cannot reach Radarr or Sonarr | Wrong address or API key | Test the connection under **Settings** |
| Logs | | `sudo hs ct maintainerr logs 100` (docker mode: the logs command above) |

## Next
- [Films: Radarr](radarr.md)
- [Series: Sonarr](sonarr.md)
- [Films and series on autopilot](jellyfin.md)
