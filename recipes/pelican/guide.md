# Game servers with Pelican

Run a Pelican Panel (the web page) and Wings (the program that starts the game servers) in two containers, and let friends play.

Not tested on hardware yet: the recipe's own installers (they replaced the earlier community installer; the pinned releases and the adoption of existing containers have not run on a real server). The browser steps below were done on a real setup.

## Before you start
- A server with Docker-capable containers and the folder `/bulk/sensitive` for backups ([Storage and disks](storage-and-disks.md)).
- A reverse proxy for the public addresses, for example the Zoraxy container, and two names, `panel.example.com` and `wings.example.com`. Without public access you can use the container addresses and skip the proxy steps.
- Game traffic and SFTP do not pass through a web tunnel (Cloudflare and similar carry only HTTP): players reach game ports over the local network or Tailscale.

## How the parts fit

| Part | Container | Reached at |
| --- | --- | --- |
| Pelican Panel (web page) | `pelican-panel` | `https://panel.example.com` |
| Wings (runs the game servers) | `pelican-wings` | `https://wings.example.com` |
| Game ports | `pelican-wings` | the container's address, or Tailscale |

A request from the internet goes browser, tunnel, reverse proxy, then Panel or Wings. Outside is HTTPS; Panel and Wings themselves speak HTTP.

## Set it up

```bash
sudo hs recipe pelican
```

The recipe asks nothing, so it also runs from the web interface. It creates both containers and installs both parts itself from pinned releases of the makers, checking their checksums:
- **Panel:** nginx, PHP-FPM and Composer; the Panel in `/opt/pelican-panel`; a queue worker and a scheduler as systemd units. The database is SQLite, chosen in the Panel's web installer, so there is no database server to keep running.
- **Wings:** Docker inside, the Wings binary, its unit, `/etc/pelican` for the config the Panel gives you, a 100 GB disk, and the folder `/bulk/sensitive/pelican-backups` mounted at `/var/lib/pelican/backups`.
- Fixed addresses for both (when your router connection is set up) and `APP_URL` set to the Panel's address.

Run `sudo hs recipe pelican --check` to see what a run would change. Containers set up earlier by hand are adopted as they are; `--update` moves them to the pinned release.

## Finish the Panel
1. Open `http://<address of pelican-panel>/installer`. Choose **SQLite**, keep the suggested name `database.sqlite`, and create your admin account. Switch on two-factor login in your profile: the Panel can create and delete servers.
2. Run the recipe once more. It starts the queue worker, which needs the key the installer made.

```bash
sudo hs recipe pelican
```

3. For public access, add two rules in the reverse proxy: `panel.example.com` to `<panel address>:80` and `wings.example.com` to `<wings address>:8080`, both with "Target is HTTPS" off and without Basic Auth or proxy login (that would break the Panel's login). Then set the public address in the Panel's `.env` (`APP_URL=https://panel.example.com` and `TRUSTED_PROXIES=<address of the proxy>`) and clear the cache. Run `artisan` as `www-data`, never as root: files root creates in the cache cause error 500.

```bash
sudo hs ct pelican-panel exec bash -c 'cd /opt/pelican-panel && runuser -u www-data -- php artisan optimize:clear'
```

From now on open the Panel only through `https://panel.example.com`.

## Add the node and connect Wings
1. In the Panel: **Admin > Nodes > Create**. Domain `wings.example.com`, "Communicate over SSL" set to HTTPS with a reverse proxy, connection port `443`, listening port `8080`, SFTP port `2022`. Create the node only once.
2. Open the node's **Configuration** tab, copy it, and replace the whole file in the Wings container.

```bash
sudo hs ct pelican-wings exec nano /etc/pelican/config.yml
```

Check that it holds `api.host: 0.0.0.0`, `api.port: 8080`, `ssl.enabled: false`, `system.backup_directory: /var/lib/pelican/backups`, `sftp.bind_port: 2022` and `remote: https://panel.example.com`.

3. Restart Wings and read its log; it must show "fetching list of servers from API" without an error and then "sftp server listening".

```bash
sudo hs ct pelican-wings exec systemctl restart wings
```

4. In the reverse-proxy rule of `wings.example.com` add two **response headers**, otherwise the heart in the node list stays red: `User-Agent` with `Pelican Wings/<version> (id:<token_id>)` (the version from `wings version`, the `token_id` from `/etc/pelican/config.yml`) and `Access-Control-Expose-Headers` with `User-Agent`. The proxy removes the first header, and the browser may not read it without the second. Update the version after a Wings update.

## Ports and friends
- **Allocations:** node > **Allocations**, IP `0.0.0.0` (never the container's address: Docker then forwards only to that address and Tailscale does not work), ports such as `25565-25570`.
- **Players outside your network:** install Tailscale inside `pelican-wings`, give the Tailscale address as the allocation **alias**, and share the machine with your friends from the Tailscale admin page (switch off key expiry). Limit shared users with an access rule so they cannot reach SFTP (2022) and the Wings API (8080).
- **Backups:** per server set a backup limit (**Build configuration**) and a schedule (**Schedules > Create task > Create backup**). Files land in `/bulk/sensitive/pelican-backups`, read-only over the network on purpose: delete backups in the Panel. Everything is on the same disk, so copy them to a second place too. `database.sqlite` is not part of Pelican's backups: take a snapshot before Panel updates.

```bash
sudo hs ct pelican-panel snapshot
```

## Update and remove
- Update: raise the pins at the top of `packages/pelican/run.sh` (or install a newer package version with `hs pkg update pelican`), then run `sudo hs recipe pelican`. It downloads only what differs from the last run.
- Remove: `sudo hs ct pelican-wings remove` and `sudo hs ct pelican-panel remove` each ask you to type the name and delete the container with its data (game servers, the Panel's database). Backups in `/bulk/sensitive/pelican-backups` stay.

## Check that it worked
- The heart next to the node in the Panel is green (clear the cache and use a private window after a fix).
- `curl -sI https://wings.example.com` shows the `User-Agent` header with your `id:`.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Installer page without design | `APP_URL` points to an old address | Fix `APP_URL` in `/opt/pelican-panel/.env`, clear the cache |
| Error 500 after an `artisan` command | It ran as root | `chown -R www-data:www-data /opt/pelican-panel/storage /opt/pelican-panel/bootstrap/cache`; use `www-data` |
| Heart red, `does not match node token_id` | The two response headers are missing | Add them in the proxy rule; clear the Panel cache |
| `wings --debug`: `address already in use` | The Wings service is already running | `systemctl restart wings` |
| Proxy answers 521 | The proxy cannot reach Wings | Test from the proxy container: `curl -I http://<wings address>:8080` |
| Game works locally, not over Tailscale | The allocation uses the container's address | Create allocations with `0.0.0.0` |
| SFTP through `wings.example.com` fails | The tunnel carries only HTTP | Use `<wings address>:2022` or the Tailscale address |

## Next
- [Authentik: one login for your services](authentik.md)
