# Torrents through a VPN

Run qBittorrent so that it can only reach the internet through your VPN, and hand finished torrents to Radarr and Sonarr.

Not tested on hardware yet: the recipe is tested with dry runs and syntax checks; the containers themselves (gluetun, qBittorrent) have not been started on a real server.

## Before you start
- The share `media` and the containers `radarr` and `sonarr` ([Films and series on autopilot](radarr.md)).
- A VPN account at a provider that gluetun knows and that allows P2P (for example Mullvad, ProtonVPN, AirVPN, IVPN, NordVPN, Surfshark, Private Internet Access; the list is in the gluetun wiki).
- The login data: for WireGuard the private key and the address (`Address =` in the provider's config, like `10.2.0.2/32`); for OpenVPN the user name and password. Some providers use separate OpenVPN credentials, not the ones of their website.
- Downloading copyrighted material without permission is generally not allowed, with or without a VPN. The recipe installs tools only.

## Why a VPN, and why this way
With torrents the upload is what draws warnings: whoever downloads also shares pieces, and the other side sees your address. So qBittorrent runs only through a VPN, and not as a setting you can forget but by construction:

- The recipe creates a container with Docker and starts one Compose project with two programs: `gluetun` (the VPN client) and `qbittorrent`.
- qBittorrent uses `network_mode: service:gluetun`: it has no network of its own. When the tunnel is down it has no connection at all, a kill switch that cannot be switched off.
- gluetun lets only your home network (setting `LAN`) reach the web page.

Usenet does not need a VPN.

## Set it up

```bash
sudo hs recipe qbittorrent
```

The recipe asks (Enter keeps the default in brackets): network, storage and the port of the web page (default 80), the share name (default `media`), the **VPN provider** as gluetun names it (`mullvad`, `protonvpn`, `nordvpn` ...), the **protocol** (`wireguard` or `openvpn`), optional server countries, and then the credentials. The credentials are not shown and are written only to `/opt/qbittorrent/gluetun.env` inside the container (root only), never to the server itself or to `machine.toml`.

It also sets up:
- a fixed address like the other recipes, and the device `/dev/net/tun` in the container;
- `/media/downloads/torrents` on the share `media`. It is the same path `/media` as Radarr, Sonarr and SABnzbd, so a finished torrent is moved into the library by a hard link and keeps seeding without a second copy;
- unfinished downloads in `/var/tmp/qbt-incomplete` inside the container (SSD);
- an ntfy topic, separate from the server's alarms, and the container in the nightly backup (`hs backup ct qbittorrent off` removes it; the backup contains your VPN login).

At the end it checks the address the tunnel uses to reach the internet. If that is your own address it warns: do not use it, check the VPN settings. The page never gets a public route.

## First login
Open the address the recipe prints. The user is `admin`; the temporary password is in the log.

```bash
sudo hs ct qbittorrent exec docker logs qbittorrent
```

Look for "temporary password" and set your own under **Tools > Options > Web UI** straight away. The recipe has already set the save path `/media/downloads/torrents` and the unfinished folder `/incomplete`; check them under **Tools > Options > Downloads**.

## Add it to Radarr and Sonarr
In Radarr and in Sonarr: **Settings > Download Clients > Plus > qBittorrent**.

| Field | Value |
| --- | --- |
| Host | the address of the container `qbittorrent` (printed at the end of the recipe) |
| Port | the web page port (80 unless you changed it) |
| Username / Password | `admin` and your password |
| Category | `movies` in Radarr, `tv` in Sonarr |

Press **Test**, then **Save**. In **Settings > Media Management** keep **Use Hardlinks instead of Copy** on. Add torrent indexers in Prowlarr; with two download clients Radarr and Sonarr use the one that fits the release.

## Port forwarding (optional)
Without an incoming port you get fewer connections; downloads still work. If your provider offers port forwarding (ProtonVPN, Private Internet Access), add `VPN_PORT_FORWARDING=on` to `/opt/qbittorrent/gluetun.env` inside the container (see the gluetun wiki for your provider), restart, and enter the forwarded port under **Options > Connection**:

```bash
sudo hs ct qbittorrent exec docker compose -f /opt/qbittorrent/docker-compose.yml up -d --force-recreate
```

## Change the account, update, remove
- Another VPN account: delete the file, then run the recipe with `--ask`.

```bash
sudo hs ct qbittorrent exec rm /opt/qbittorrent/gluetun.env
```

```bash
sudo hs recipe qbittorrent --ask
```

- Update: `sudo hs recipe qbittorrent` fetches newer images and restarts; settings stay.
- Remove: `sudo hs ct qbittorrent remove` asks you to type the name and deletes the container with its settings and your VPN login. Downloaded files in `/media/downloads/torrents` stay.

## Check that it worked
- The recipe's last step reports an address that is not your own.
- Radarr's **Test** is green and a torrent added there shows up in qBittorrent.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| "The VPN did not come up" | Wrong provider name, key or address; for OpenVPN the website login was used | `sudo hs ct qbittorrent exec docker logs gluetun --tail 30` |
| `/dev/net/tun` missing | The device was not added | Run the recipe again; it adds it |
| Web page unreachable | Your computer is not in the networks of the setting `LAN` (default `10.0.0.0/8,192.168.0.0/16`) | `sudo hs recipe qbittorrent --ask` and enter your network |
| Torrent stays "Stalled" | The tunnel is down, and qBittorrent then deliberately loads nothing | Check the gluetun log |
| Radarr or Sonarr does not import | The two do not see `/media` the same way, or a remote path mapping exists | Check **Activity > Queue**; remove path mappings |
| "Permission denied" | The container's `qbittorrent` user cannot write to the share | `hs ct list`, check the container's storage |

## Next
- [Films and series on autopilot](radarr.md)
