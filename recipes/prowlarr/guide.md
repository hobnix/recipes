# Prowlarr: one place for your indexers

Set up Prowlarr to hold your Usenet indexers once and hand them to Radarr, Sonarr and Lidarr.

## Before you start
- An account at a Usenet indexer (you pay for it yourself).
- The overview of the film apps: [Films and series on autopilot](jellyfin.md). Install Prowlarr before the apps that use it, or run their recipes again afterwards.

## Set up Prowlarr
```bash
sudo hs recipe prowlarr
```

The recipe asks where it runs (own container or the container `docker`, see [the overview](jellyfin.md)) and prints the address of the page (port 9696). It mounts no share: Prowlarr never touches a file of the library. Open the page and create a login straight away (method Forms). It holds the logins of your indexers: never give it a public route.

### Docker mode
In `docker` mode the compose file is in `recipes/prowlarr` in the share `apps` (mounted at `/shares/apps` in the container `docker`; the settings in `recipes/prowlarr/config`). There is no container `prowlarr`: look at the app with:

```bash
sudo hs ct docker exec docker logs prowlarr --tail 50
```

The backup is the one of the container `docker`; the recipe only adds the database dump. Not tested on hardware yet.

## Add the indexer
Under **Indexers > Add Indexer** pick your indexer and enter its address and API key. Then set **Query Limit** and **Grab Limit** to what your plan allows, so the apps do not use up the daily limit and find the indexer paused.

## Connect Radarr, Sonarr and Lidarr
Under **Settings > Apps** add each app that you installed. Prowlarr Server is `http://<prowlarr>:9696`; the others are `http://<radarr>:7878`, `http://<sonarr>:8989` and `http://<lidarr>:8686`, each with the API key from the app's **Settings > General**. Your indexer then shows up in every app.

## Check that it worked
- `hs services list` shows Prowlarr with its container and port.
- **Indexers** shows the indexer with a green test, and Radarr shows it under **Settings > Indexers**.

## Update and remove
- Update: run the recipe again (`sudo hs recipe prowlarr`); it fetches the newer image and restarts. Your settings stay.
- Remove: `sudo hs ct prowlarr remove` asks you to type the container's name and deletes the container with its settings and databases. Restore from the backup with `hs backup`.
- Remove in `docker` mode: there is no container of the app. Run `docker compose -p prowlarr down` in `/shares/apps/recipes/prowlarr` inside the container `docker`:

```bash
sudo hs ct docker exec bash -c 'cd /shares/apps/recipes/prowlarr && docker compose -p prowlarr down'
```

This stops and removes the app's container; the settings stay in the same folder until you delete it yourself. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| "All indexers are unavailable", test is green | The indexer's daily limit is used up and the apps paused it | Set **Query Limit** and **Grab Limit** on the indexer; restart the app (`sudo hs ct sonarr exec docker restart sonarr`) |
| Search finds nothing though the indexer has it | Releases carry another title than the one Sonarr searches | Search in Prowlarr with both titles |
| An app does not receive the indexer | Wrong address or API key under **Settings > Apps** | Test the entry; use the app's address, not `localhost` |
| Logs | | `sudo hs ct prowlarr logs 100` (docker mode: the logs command above) |

## Next
- [Films: Radarr](radarr.md)
- [Series: Sonarr](sonarr.md)
- [Films and series on autopilot](jellyfin.md)
