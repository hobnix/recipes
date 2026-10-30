#!/usr/bin/env bash
# recipe: Radarr: keeps your films in order: searches them, sends the download to SABnzbd, files it in the library
# recipe.de: Radarr: hält deine Filme in Ordnung: sucht sie, schickt den Download an SABnzbd, legt ihn in der Bibliothek ab
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "radarr" with Docker inside and runs, from their makers' images:
#   Radarr (7878)      films: searches, sends the download to SABnzbd, renames and files it in /media/movies
#   Recyclarr          not running: a tool for `docker compose run`, which syncs the quality profiles of the
#                      TRaSH guides (German ones included) into Radarr
# The other apps of the group are recipes of their own: sonarr (series), lidarr (music), prowlarr (indexers),
# bazarr (subtitles), maintainerr (clean-up rules); the downloader is "sabnzbd", the request page "seerr", the
# conversion at night "tdarr". Their guide is the one of this recipe.
#   share              the share "media" (the one of Jellyfin), READ-WRITE at /media with a user "radarr" mapped 1:1,
#                      the same path SABnzbd uses: a finished download moves into the library by a hard link
#   config             /opt/radarr/config inside the container (SSD pool); `hs backup ct radarr on` is switched on and a
#                      dump of the databases is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/radarr)
#   push messages      the topic of the film apps (state/media-ntfy), see the closing text
#   duplicates         a nightly job (hs-arr-dedupe.py, timer hs-arr-dedupe) for films with two files in one folder
#                      (e.g. 2160p and 1080p): the lower resolution is announced, then deleted after 14 days; a
#                      Maintainerr rule cannot do that (it deletes whole films). Messages go to ntfy and Matrix as
#                      "Maintainerr (Script)". Veto: a file .keep-both in the film's folder.
# No Zoraxy rule: Radarr is an admin page for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-radarr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=7878   # Radarr's own port: Prowlarr, Seerr and Bazarr are told this one

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 1536 MB RAM limit) unless it exists, with a fixed address (.50-.99) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media, with folders movies, series, music, downloads"
  say "  start Radarr (port 7878) and install Recyclarr as a tool"
  say "  use the push topic of the film apps, and put the container in the nightly backup with a database dump"
  say "  (if you say yes) install a nightly job that announces and then deletes the lower-resolution file of a film that has two (messages to ntfy and Matrix)"
  exit 0
fi

setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
setting DEDUPE "Delete the lower-resolution file when a film has two (say 4K and FullHD) in its folder, after a grace period? yes or no" yes no "yes|no"
setting DEDUPE_DAYS "Grace period in days before that file is deleted (it is announced first)" 14 14 "[1-9][0-9]{0,2}"
ensure_container "$ct" 1536 --docker
fixed_address "$ct" 50 99
wait_internet "$ct"
media_storage radarr
install_docker

step "Radarr"
# docker-compose.yml is written again at every run; Radarr's own data stays in /opt/radarr/config
compose='mkdir -p /opt/radarr/config /opt/radarr/recyclarr
  cat > /opt/radarr/docker-compose.yml.new <<YML
services:
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports: ["7878:7878"]
    environment:
      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002
    volumes: ["/opt/radarr/config:/config", "/media:/media"]
  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:8
    container_name: recyclarr
    user: "$2:$3"
    profiles: ["tools"]
    environment:
      - TZ=$1
    volumes: ["/opt/radarr/recyclarr:/config"]
YML
  mv /opt/radarr/docker-compose.yml.new /opt/radarr/docker-compose.yml
  chown -R "$2:$3" /opt/radarr
  cd /opt/radarr && docker compose --profile tools config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings" "$compose" "$tz" "${ids%%:*}" "${ids##*:}"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Radarr not started"
else
  in_ct "Downloading Radarr and Recyclarr" 'cd /opt/radarr && docker compose --profile tools pull -q'
  in_ct "Starting Radarr" 'cd /opt/radarr && docker compose up -d --remove-orphans'
  wait_page Radarr "docker compose -f /opt/radarr/docker-compose.yml logs --tail 50"
fi

step "Settings"
# Through Radarr's own API (v3): Recycling Bin (a deleted or replaced file waits 7 days) and, when a SABnzbd client
# exists, "Remove Completed". Run the recipe again after adding the SABnzbd client by hand.
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no settings written"
else
  akey=$(incus exec "$ct" -- sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' /opt/radarr/config/config.xml </dev/null 2>/dev/null | head -n1 || true)
  if [ -z "$akey" ]; then
    warn "No API key found yet, settings not written (run the recipe again)"
  else
    res=$(bash "$(dirname "$0")/arr-tune.sh" "$ip" "$PORT" "$akey" /media/downloads/recycle 7 2>/dev/null || true)
    case "$res" in *recycle=set*|*recycle=same*) ok "Recycling Bin /media/downloads/recycle, emptied after 7 days" ;; *) warn "Recycling Bin not set. Click: Settings -> Media Management -> Recycling Bin" ;; esac
    case "$res" in
      *client=set*|*client=same*) ok "The SABnzbd client removes completed downloads" ;;
      *client=none*) note "No SABnzbd client yet; add it (step 2 below), then run this recipe again for Remove Completed" ;;
      *) warn "Remove Completed not set. Click: Settings -> Download Clients -> SABnzbd -> Remove Completed" ;;
    esac
  fi
  if incus info jellyfin >/dev/null 2>&1; then
    note "Jellyfin: Settings -> Connect -> + -> Emby/Jellyfin: host, port 8096, API key (Jellyfin: Dashboard -> API Keys), tick Update Library. Not set by the recipe: the key needs a Jellyfin login"
  fi
fi

step "Backup"
# Radarr keeps SQLite databases, which must not be copied while they are written. The dump goes to
# /var/backups/hs/radarr (Radarr's files themselves are in the backup too); the posters/fanart cache
# (MediaCover) is large and gets fetched again, but it is in the backup as well.
install_dump_tool sqlite
media_backup "/usr/local/sbin/hs-dump sqlite-tree radarr /opt/radarr"
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

media_ntfy

step "Duplicates"
dedupe_line=""
if [ "$DEDUPE" = yes ]; then
  in_ct "Installing ffprobe and Python" '$1 update -qq && $1 install -y -qq --no-install-recommends ffmpeg python3-minimal ca-certificates' "$apt_quick"
  spin "Copying the programs" bash -c 'incus exec "$2" -- mkdir -p /opt/radarr/dedupe /usr/local/lib/hs &&
    incus file push -q --mode 0755 "$1/hs-arr-dedupe.py" "$3/files/hs-media-notify.py" "$2/usr/local/lib/hs/"' _ "$(dirname "$0")" "$ct" "$scripts/recipes"
  media_notify_conf "$ct" /usr/local/lib/hs
  in_ct "Setting up the nightly job" 'chown -R "$1:$2" /opt/radarr/dedupe
    cat > /etc/systemd/system/hs-arr-dedupe.service <<UNIT
[Unit]
Description=Announce and delete the lower-resolution copy of films that have two files
[Service]
Type=oneshot
User=$1
ExecStart=/usr/bin/python3 /usr/local/lib/hs/hs-arr-dedupe.py --days $3
UNIT
    cat > /etc/systemd/system/hs-arr-dedupe.timer <<UNIT
[Unit]
Description=Nightly duplicate check
[Timer]
OnCalendar=*-*-* 03:30
RandomizedDelaySec=10min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload && systemctl enable --now hs-arr-dedupe.timer' "${ids%%:*}" "${ids##*:}" "$DEDUPE_DAYS"
  ok "$(t "Every night at 03:30: a film with two resolutions is announced, its lower file deleted after %s days" "$DEDUPE_DAYS")"
  dedupe_line="$(t "Duplicates: list what would happen:  incus exec %s -- python3 /usr/local/lib/hs/hs-arr-dedupe.py --dry-run   (keep both: touch .keep-both in the film's folder)" "$ct")"
else
  note "Skipped: no duplicate cleanup (hs recipe radarr --ask turns it on)"
fi

declare_service radarr Radarr radarr never-public Media "Films: searches, downloads and files them"

recipe_facts web
box <<DONE
$(say "No Zoraxy rule: it is for the home network only. The few clicks that cannot wait:")
$(say "1. Settings -> Media Management -> Root Folder:  /media/movies")
$(say "2. Settings -> Download Clients -> SABnzbd (hs recipe sabnzbd), category  movies, then run this recipe again")
$(say "3. Prowlarr (hs recipe prowlarr): Settings -> Apps -> Radarr, this address and the API key (Settings -> General)")
$(t 'Push messages (Settings -> Connect -> ntfy):  server %s   topic %s' "$ntfy_server" "$ntfy_topic")
$dedupe_line
$(docs_hint radarr)
DONE
