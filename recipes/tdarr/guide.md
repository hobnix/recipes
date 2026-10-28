# Convert films for Jellyfin

Let Tdarr add an audio track to your films once, at night, so Jellyfin starts them at once instead of converting the sound on every play.

Not tested on hardware yet: the plugin is tested against real ffmpeg runs (`tests/tdarr-plugin.sh`), its cooperation with Tdarr itself is not.

## Before you start
- The `jellyfin` recipe is set up: it creates the share `media` that Tdarr works on. See [Films and series on autopilot](arr.md).
- You accept that Tdarr changes files in the share (the original is kept as a hard link, see below).

## Why
Some films start only after many seconds. Example: a 4K film with Dolby Vision video and TrueHD Atmos sound. The browser cannot play that sound, so Jellyfin builds a new stream at every start and every seek: ffmpeg reads up to 1 GB of the file, converts the sound and cuts it into pieces. Tdarr does this work once, at night, and adds an audio track that browsers and TVs can play. The picture is not changed.

## Set it up

```bash
sudo hs recipe tdarr
```

The recipe creates the container `tdarr` with Docker inside, mounts the share `media` read-write at `/media` (a user `tdarr` is mapped 1:1, so the files stay the share owner's on disk) and installs the plugin of this server. Then, once in the browser (the address is printed at the end):

1. **Libraries > Library +**: name `Movies`, source `/media/movies`. Add a second library for `/media/series`. Never add `/media/music` or `/media/_tdarr-originals`.
2. **Transcode options**: cache `/temp`, leave "Output folder" empty (the new file replaces the old one). In the plugin stack use only **Homeserver: make it easy for Jellyfin** (search for `Jellyfin`).
3. On the library's **Source** tab switch on "Folder watch" and "Scan on start". Back in the library list: **Library options > Scan (Fresh)**.
4. **Nodes > `hs-node`**: the recipe sets one CPU transcode worker. **With no worker (all numbers 0) nothing happens** and the queue stands still, so check that Transcode CPU is 1. Set the night hours (01:00 to 06:00) in the node's schedule per hour: outside them 0 workers; a film that is running is finished.

The Tdarr page has no login. Never give it a public route.

## What the plugin does

| Case | Effect |
| --- | --- |
| A language has only TrueHD, DTS or DTS-HD audio | A new AC3 track (5.1, 640 kbit/s) is added first and marked default; the original track stays behind it |
| The picture | Never changed (copied bit for bit), also HDR and Dolby Vision |
| Old video format: DivX/Xvid, WMV, VC-1, MPEG-1/2, H.264 10-bit/4:2:2 | Becomes H.264 at high quality (CRF 18, NVENC with an NVIDIA card); rare |
| Container `avi`, `ts`, `wmv` and similar | Becomes `mkv` without re-encoding |
| Already fine | Nothing happens |
| Before any change | The original stays as a hard link in `/media/_tdarr-originals/<same path>`; if the link cannot be made, the film is left alone |

A hard link costs no space until the film is replaced. After that the original and the new file both use disk (the new one is roughly 300 to 500 MB bigger).

## Add AAC for browsers
Chrome and Firefox often cannot play AC3 (Edge and Safari usually can), so Jellyfin still converts. Set the plugin input `addAac` to `true` (Tdarr > plugin stack). Every new AC3 track then gets an AAC stereo track that plays everywhere.

## After the run
- Jellyfin notices changed files at the next library scan (**Dashboard > Libraries > Scan**). It picks the audio track by language; the new AC3 track is first and marked "Default".
- When you are happy with the result, delete the originals. This cannot be undone.

```bash
sudo rm -r /bulk/shares/media/_tdarr-originals
```

- The folder and all changes live in the share `media`: they are in `hs backup`, and the SnapRAID parity changes with them, so the next sync takes longer.

## Update and remove
- Update: `sudo hs recipe tdarr` fetches the newest image.
- Remove: `sudo hs ct tdarr remove` asks you to type the name and deletes the container with its settings. Films and `_tdarr-originals` stay in the share.

## Check that it worked
- Tdarr's node page shows a worker and the library scan lists your films.
- After a run, a film with TrueHD or DTS shows an extra AC3 track first (in Jellyfin's audio menu).

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Queue does not move | No transcode worker on the node | Set Transcode CPU to 1 on `hs-node` |
| Film unchanged | The hard link could not be made | The share must allow links between its folders; see the arr guide |
| DVD rips take long | MPEG-2 video is converted to H.264 | Expected: minutes to half an hour per film; Blu-rays keep their picture |

## Next
- [Jellyfin and your own discs](jellyfin.md)
