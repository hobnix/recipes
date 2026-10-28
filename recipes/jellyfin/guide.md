# Jellyfin, and your own discs

Set up Jellyfin for films, series and music on the server, then turn your DVDs and Blu-rays into files it can play.

## Before you start
- A running server with bulk storage ([Storage and disks](storage-and-disks.md)).
- For ripping: a Windows PC with a disc drive (a DVD drive reads DVDs; Blu-rays need a Blu-ray drive, external USB ones from about 60 EUR are fine). 4K Ultra HD discs need a LibreDrive-capable drive; the list is in the MakeMKV forum.
- Free space on the PC: about 4 to 8 GB per DVD, 20 to 40 GB per Blu-ray, 50 to 90 GB per 4K disc.

## Set up Jellyfin

```bash
sudo hs recipe jellyfin
```

The recipe creates the container `jellyfin` and installs Jellyfin from its package source. It asks for the **share name** (default `media`, under `/bulk/shares`) and creates it with the folders `movies`, `series`, `music`, `anime/series` and `anime/movies`. The share is mounted read-only at `/media`: Jellyfin only reads, so it can never delete or change a film. It also passes a graphics card into the container (NVIDIA, else the processor's Intel or AMD chip) so videos can be converted for devices that need it without loading the CPU, and it asks once about the optional dark "Abyss" theme (default no).

Jellyfin's own data (users, posters, what was watched) is on the SSD pool inside the container. Open the address the recipe prints (port 8096 unless you chose another); the first visit sets up the admin account. Add libraries for `/media/movies`, `/media/series` and `/media/music`.

## Rip a disc with MakeMKV
MakeMKV reads a disc and saves film and sound unchanged as an `.mkv` file. Nothing is re-encoded; the quality is that of the disc. MakeMKV runs on the Windows PC (that is where the drive is), the server only receives the finished files through the share.

Cost: MakeMKV is free while in beta, but its registration key is valid only about a month and is posted in the MakeMKV forum. A licence (a one-time payment of about 50 EUR) covers all 1.x versions and pays off after a few discs.

1. Start MakeMKV, insert the disc, click the large drive icon. After the disc structure is read (about a minute for a Blu-ray) the list of titles appears.
2. Find the main title: the longest one (1:30 to 2:30 hours for a film). Blu-rays have many similar playlists: take the longest, and when several are close the one with the largest file.
3. Choose tracks: keep the video; audio in your language and the original language (drop commentary tracks; of two versions in one language take the better format: TrueHD or DTS-HD before AC3 or DTS); subtitles in your language, "forced" subtitles (foreign speech only) and English.
4. Choose an output folder on a local SSD, for example `D:\rips\Film Name (Year)`, and press **Make MKV**. A DVD takes 10 to 20 minutes, a Blu-ray 30 to 60. Ripping to a local disk first is much faster than writing over the network.

Tips:
- Under **File > Preferences > Video** set the minimum title length to 1200 seconds: menus, trailers and ads are then not listed.
- A series DVD has one title per episode (30 to 60 minutes): tick them all and MakeMKV numbers them.
- Read errors are almost always scratches or dirt: wipe the disc with a soft cloth from the centre outwards and try again, or try another drive.
- MakeMKV bypasses the copy protection automatically. In some countries this is illegal even for private copies of your own discs (in Germany, section 95a of the copyright act). It is your decision and responsibility: copy only discs you own and do not pass the files on.

## Name the files and put them on the server
Jellyfin recognises films only when folder and file are named like the film database:

```
\\<server>\media\movies\Film Name (1972)\Film Name (1972).mkv
\\<server>\media\series\Show Name (1989)\Season 01\Show Name S01E01.mkv
```

- The year in brackets matters for films; it separates films with the same name.
- Several versions of one film: `Film Name (1972) - Director's Cut.mkv` in the same folder.
- Series: `S01E01`, `S01E02` and so on, one folder `Season 01` per season.

The share `media` is read-only for Jellyfin but writable for you over the network (see [Users and shares](users-and-shares.md)). Copy the finished folder, then scan: **Dashboard > Libraries > Scan** (Jellyfin also scans by itself). A film that does not match is usually named wrongly: rename it and scan again.

## Afterwards: Tdarr
The [Tdarr plugin](tdarr.md) adds an AC3 audio track to films that have only TrueHD or DTS sound, so TVs and browsers play them. A DVD's picture is MPEG-2; the plugin turns it into H.264 (smaller, no visible difference), which takes a few minutes to half an hour per film. Blu-ray pictures stay unchanged.

You can skip: Handbrake (MakeMKV plus Tdarr replace it; re-encoding a 30 GB Blu-ray to 8 to 10 GB with H.265 saves space but costs quality and time, and is not needed) and ISO images (the `.mkv` is enough to play; keep the discs as your backup).

## Check that it worked
- The library shows the film with poster and description, and it plays on the TV or in the browser.
- `hs ct list` shows the container `jellyfin` running.

## Update and remove
- Update: `sudo hs ct jellyfin update` makes a snapshot, then updates the software inside. The recipe `sudo hs recipe jellyfin` can be run again at any time.
- Remove: `sudo hs ct jellyfin remove` asks you to type the name and deletes the container with its users and watch history. The share `media` and your films stay.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Film shows the wrong title or none | Folder or file name does not match the film | Rename as above, scan again |
| Disc will not read | Scratches, dirt, or a 4K disc without a LibreDrive drive | Clean it; try another drive |
| A film starts only after many seconds | The sound has to be converted at every start | Let [Tdarr](tdarr.md) add an AC3 track |
| Jellyfin cannot see new files | The library has not been scanned | **Dashboard > Libraries > Scan** |

## Next
- [Films and series on autopilot](arr.md)
- [Convert films for Jellyfin](tdarr.md)
