# Configarr: quality profiles from your repository

Set up Configarr to copy your quality profiles and custom formats (for example the German ones of the TRaSH guides) from a private git repository into Radarr and Sonarr every night.

## Before you start
- [Radarr](radarr.md) and [Sonarr](sonarr.md) are installed (one of them is enough: the other is left out). The overview of the film apps is in [Films and series on autopilot](jellyfin.md).
- A private repository, for example on GitHub, with the files listed under "What the repository must contain". Configarr itself is described at https://configarr.de.
- The recipe needs the internet: it fetches the TRaSH guides at every run.

## Set up Configarr
```bash
sudo hs recipe configarr
```

The recipe asks for the SSH address of your repository (`git@github.com:<owner>/<repo>.git`), the time of the nightly sync (default 03:45) and where it runs (own container or the container `docker`, see [the overview](jellyfin.md)). It finds Radarr and Sonarr by the name `radarr` and `sonarr`, reads their addresses and API keys, and writes them to `secrets.yml` on the server. The keys never go into your repository.

It then makes a deploy key and prints its public half in the closing box. The first pull fails until you add the key.

## Add the deploy key
1. Open the repository on GitHub: **Settings > Deploy keys > Add deploy key**.
2. Paste the key from the box. Leave **Allow write access** off.
3. Run the recipe again:

```bash
sudo hs recipe configarr
```

The pull works now, and Configarr runs within a minute. For a host other than `github.com` the recipe takes the host key on first contact and tells you to check its fingerprint.

## What the repository must contain
| Item | Value |
| --- | --- |
| `config.yml` | At the root of the repository (the default branch is used) |
| Secrets | `config.yml` uses `!secret RADARR_URL`, `RADARR_API_KEY`, `SONARR_URL` and `SONARR_API_KEY`, exactly these names |
| `templates/` | Optional: your own config templates. In `config.yml`: `localConfigTemplatesPath: /app/templates` |
| `cfs/` | Optional: your own custom formats. In `config.yml`: `localCustomFormatsPath: /app/cfs` |
| `secrets.yml` | Never in the repository (put it in `.gitignore`) |

Both folders are also at `/profile/templates` and `/profile/cfs` inside the container. Leave a `local*Path` key out when its folder is missing. If Radarr or Sonarr is not installed, the recipe leaves that block (`radarr:` or `sonarr:`) out of a copy of `config.yml`, so the file may keep both.

## Sync now
Pull the repository and run Configarr at once (the run follows within a minute). Not tested on hardware yet.

```bash
sudo hs ct configarr exec docker exec configarr-git sh /hs/pull.sh
```

In `docker` mode:

```bash
sudo hs ct docker exec docker exec configarr-git sh /hs/pull.sh
```

A run that only shows what Configarr would change (nothing is written):

```bash
sudo hs ct configarr exec docker exec -e DRY_RUN=true configarr sh /hs/run.sh
```

## See the result
The state is in `/opt/configarr/hs/state` (docker mode: `/shares/apps/recipes/configarr/hs/state` in the container `docker`). One line each: `ok` or `failed`, the time and a reason.

```bash
sudo hs ct configarr exec cat /opt/configarr/hs/state/pull.status
```

```bash
sudo hs ct configarr exec cat /opt/configarr/hs/state/run.status
```

The log of the newest run:

```bash
sudo hs ct configarr exec sh -c 'tail -n 50 $(ls -1 /opt/configarr/hs/logs/run-*.log | tail -n 1)'
```

The newest 14 days of logs are kept. A failed sync also sends a push message to the topic of the film apps, once per failure (only after a pull has worked once). The profiles show up under **Settings > Profiles** in Radarr and Sonarr.

## Coming from Recyclarr
Move what you used from `recyclarr/configs` into `config.yml` and `templates/` in your repository (Configarr reads Recyclarr's templates). Delete the old folders once the profiles are in: `/opt/radarr/recyclarr` and `/opt/sonarr/recyclarr` in the containers, or `recipes/radarr/recyclarr` and `recipes/sonarr/recyclarr` in the share `apps`.

## Check that it worked
- `hs ct list` shows the container `configarr` (not in `docker` mode: look at `docker ps` in the container `docker`).
- `pull.status` and `run.status` say `ok`.
- `secrets.yml` has mode 600: `ls -l /opt/configarr/secrets`.

## Update and remove
- Update: run the recipe again; it writes the scripts anew, pulls the image and restarts. Run it again after Radarr or Sonarr got a new API key or a new address too.
- Remove: `sudo hs ct configarr remove` asks you to type the container's name. In `docker` mode run `docker compose -p configarr down` in `/shares/apps/recipes/configarr` inside the container `docker`. Delete the deploy key in the repository settings.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| `pull.status`: failed, `Permission denied (publickey)` in `pull.log` | The deploy key is not added | Add it (above), run the recipe again |
| `config.yml missing at the repo root` | The file is in a folder or named differently | Move it to the root of the default branch |
| `run.status` failed | Configarr says why in the run log | Fix `config.yml`, then sync now |
| Radarr or Sonarr unreachable | Its address changed | Run the recipe again |
| "No Radarr and no Sonarr found" | Their names differ | `sudo hs recipe configarr --ask` and give the names |

The logs are in `hs/logs` next to the state (`pull.log`, `run-<day>.log`).

## Next
- [Radarr](radarr.md) and [Sonarr](sonarr.md) show the profiles under **Settings > Profiles**.
