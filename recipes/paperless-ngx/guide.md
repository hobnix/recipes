# Your documents, searchable

Paperless-ngx keeps your paper documents: you scan them, it reads the text (OCR), files them and lets you search everything in the browser. The recipe runs it in its own container, with the documents on a sensitive share of your bulk disks.

Not tested on hardware yet.

## Before you start
- A pool for bulk data ([Storage](storage-and-disks.md)): the documents live under `/bulk/sensitive`.
- A share user with write access, if a scanner should save into the server ([Users and shares](users-and-shares.md)).

## Set it up

```bash
sudo hs recipe paperless-ngx
```

The recipe asks:
- the port of the web page (default 80),
- the name of the folder for the documents (default `paperless`, under `/bulk/sensitive`, also the share's name),
- the OCR languages as Tesseract codes joined with `+` (English, German, French, Italian and Spanish are built in; others are downloaded at every start),
- the time zone,
- whether to import office documents and e-mails (Tika and Gotenberg),
- whether to share the consume folder over the network for a scanner,
- a public address, empty by default. Leave it empty unless the page gets a public route (see "Keep it private").

It creates the container `paperless-ngx` with Docker inside and starts Paperless-ngx 3.5.1 from its official compose file (pinned and checked with sha256). It makes the secret key, the database password and the admin password once and keeps them in `/opt/paperless-ngx/.env` inside the container, readable by root only. It prints the login `admin` with its password once.

## Log in and change the password
1. Open the address the recipe printed and log in as `admin` with the printed password.
2. Open the profile menu (top right), change the password and keep it safe. The recipe never shows it again.

## Add documents
- Upload them in the browser (drag them onto the page).
- Or put files into the consume folder: Paperless picks them up, reads them and files them.
- Scanner: answer yes at the scanner question. The recipe makes the share `<folder>-consume` (path `\\<server>\<folder>-consume`) and Paperless checks it every 60 seconds. Give the scanner's user write access:

```bash
sudo hs manage-shares
```

Not tested on hardware yet.

## Office documents and e-mails
Run the recipe again with the questions and answer yes at the office question. Tika and Gotenberg start next to Paperless and need about 1 GB more RAM. Answer no later to remove them.

```bash
sudo hs recipe paperless-ngx --ask
```

Not tested on hardware yet.

## Keep it private
**Paperless-ngx holds sensitive documents. Keep it private.** The route is private by default: reachable from the home network or over Tailscale. A public route is not recommended. If you need one, put it only behind a login, for example Authentik forward auth ([One login](authentik.md)).

If the page gets a public name behind a reverse proxy, logging in can fail with a CSRF error. The public address question fixes that: run `sudo hs recipe paperless-ngx --ask` and give the address as scheme and host only, for example `https://docs.example.com` (no path, no trailing slash), then make the route in your reverse proxy. Not tested on hardware yet.

## Backup
The container is in the nightly backup with a database dump. The documents are in the share, which is a separate switch:

```bash
sudo hs backup paperless on
```

Use your own folder name instead of `paperless` if you chose another. As an extra copy, Paperless can export everything (documents and data) into `/mnt/paperless/export`. This uses the long form, because there is no `hs` command for it:

```bash
sudo incus exec paperless-ngx -- docker compose -f /opt/paperless-ngx/docker-compose.yml exec -T webserver document_exporter ../export
```

## Check that it worked
1. The login page answers at the printed address.
2. Upload a test PDF: after a short time its text appears in the document and the search finds it.

## Update and remove
A newer recipe version brings a newer pinned Paperless-ngx release. Fetch it and run the recipe again; the secrets and your documents stay.

```bash
sudo hs pkg update
```

```bash
sudo hs recipe paperless-ngx
```

To remove the container (you type its name to confirm):

```bash
sudo hs ct paperless-ngx remove
```

The documents share stays on the disks.

## If something goes wrong

| What you see | What to do |
| --- | --- |
| The login page does not answer | The first start runs the database migrations and can take minutes. Look at the log: `sudo incus exec paperless-ngx -- docker compose -f /opt/paperless-ngx/docker-compose.yml logs --tail 50` |
| A scanned file is not picked up | Check that the scanner's user has write access (`sudo hs manage-shares`) and wait 60 seconds. |
| CSRF error behind a reverse proxy | The public address is missing. Run `sudo hs recipe paperless-ngx --ask` and give it. |
| "The checksum ... does not match the pin" at install | Nothing was installed. Report it: the pinned file changed. |

## Next
- [One login](authentik.md) in front of services that people reach from outside.
