#!/usr/bin/env bash
# recipe: arr: Radarr, Sonarr and Lidarr keep your films, series and lidarr in order, Prowlarr holds the indexers, Bazarr fetches subtitles
# recipe.de: arr: Radarr, Sonarr und Lidarr halten Filme, Serien und Musik in Ordnung, Prowlarr verwaltet die Indexer, Bazarr holt Untertitel
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "arr" with Docker inside and runs, from their makers' images:
#   Radarr (7878)      films: searches, sends the download to SABnzbd, renames and files it in /media/movies
#   Sonarr (8989)      the same for series, in /media/series
#   Lidarr (8686)      the same for music, in /media/music
#   Prowlarr (9696)    your Usenet indexer(s), handed to Radarr, Sonarr and Lidarr (sync)
#   Bazarr (6767)      bazarr for what Radarr and Sonarr hold (not Lidarr)
#   Maintainerr (6246) cleans up unwatched media by rules YOU write (it has no rules at first, deletes nothing)
#   Recyclarr          not running: a tool for `docker compose run`, which syncs the quality profiles of the
#                      TRaSH guides (German ones included) into Radarr and Sonarr (the guides have none for Lidarr)
# The downloader is the recipe "sabnzbd", the request page "seerr", the conversion at night "tdarr".
#   share              the share "media" (the one of Jellyfin), READ-WRITE at /media with a user "arr" mapped 1:1,
#                      the same path SABnzbd uses: a finished download moves into the library by a hard link
#   config             /opt/arr/<app> inside the container (SSD pool); `hs backup ct arr on` is switched on and a
#                      dump of the databases is written right before each backup (hs-dump sqlite-tree, into /var/backups/hs/arr)
#   push messages      a topic of their own (state/media-ntfy), see the closing text
#   duplicates         a nightly job (hs-arr-dedupe.py, timer hs-arr-dedupe) for films with two files in one folder
#                      (e.g. 2160p and 1080p): the lower resolution is announced, then deleted after 14 days; a
#                      Maintainerr rule cannot do that (it deletes whole films). Messages go to ntfy and Matrix as
#                      "Maintainerr (Script)". Veto: a file .keep-both in the film's folder.
# None of these pages may get a Zoraxy rule: the apps are admin pages for the home network.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-arr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 3072 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media, with folders movies, series, music, downloads"
  say "  start Radarr, Sonarr, Lidarr, Prowlarr, Bazarr and (if you say yes) Maintainerr; install Recyclarr as a tool"
  say "  make a push topic of its own for them, and put the container in the nightly backup with a database dump"
  say "  (if you say yes) install a nightly job that announces and then deletes the lower-resolution file of a film that has two (messages to ntfy and Matrix)"
  exit 0
fi

setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
setting MAINTAINERR "Install Maintainerr (cleans up unwatched media by your own rules, deletes nothing at first)? yes or no" yes no "yes|no"
setting DEDUPE "Delete the lower-resolution file when a film has two (say 4K and FullHD) in its folder, after a grace period? yes or no" yes no "yes|no"
setting DEDUPE_DAYS "Grace period in days before that file is deleted (it is announced first)" 14 14 "[1-9][0-9]{0,2}"
ensure_container "$ct" 3072 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
media_storage arr
install_docker

step "The apps"
# docker-compose.yml is written again at every run; the apps' own data stays in /opt/arr/<app>
compose='mkdir -p /opt/arr/radarr /opt/arr/sonarr /opt/arr/lidarr /opt/arr/prowlarr /opt/arr/bazarr /opt/arr/recyclarr /opt/arr/maintainerr
  lsio="      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002"
  {
    cat <<YML
services:
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports: ["7878:7878"]
    environment:
$lsio
    volumes: ["/opt/arr/radarr:/config", "/media:/media"]
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports: ["8989:8989"]
    environment:
$lsio
    volumes: ["/opt/arr/sonarr:/config", "/media:/media"]
  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    restart: unless-stopped
    ports: ["8686:8686"]
    environment:
$lsio
    volumes: ["/opt/arr/lidarr:/config", "/media:/media"]
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    ports: ["9696:9696"]
    environment:
$lsio
    volumes: ["/opt/arr/prowlarr:/config"]
  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports: ["6767:6767"]
    environment:
$lsio
    volumes: ["/opt/arr/bazarr:/config", "/media:/media"]
  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:8
    container_name: recyclarr
    user: "$2:$3"
    profiles: ["tools"]
    environment:
      - TZ=$1
    volumes: ["/opt/arr/recyclarr:/config"]
YML
    if [ "$4" = yes ]; then
      cat <<YML
  maintainerr:
    image: ghcr.io/maintainerr/maintainerr:latest
    container_name: maintainerr
    user: "$2:$3"
    restart: unless-stopped
    ports: ["6246:6246"]
    environment:
      - TZ=$1
    volumes: ["/opt/arr/maintainerr:/opt/data"]
YML
    fi
  } > /opt/arr/docker-compose.yml.new
  mv /opt/arr/docker-compose.yml.new /opt/arr/docker-compose.yml
  chown -R "$2:$3" /opt/arr
  cd /opt/arr && docker compose --profile tools config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings" "$compose" "$tz" "${ids%%:*}" "${ids##*:}" "$MAINTAINERR"

# the start page and the routing by name that an earlier version made in this container (compose service gateway, nginx on port 80) are gone:
# `up --remove-orphans` below removes the old container; the files are cleaned up here
in_ct "Removing the old start page" 'rm -rf /opt/arr/gateway'

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, nothing started"
else
  in_ct "Downloading the apps (about 1.5 GB, this takes a while)" 'cd /opt/arr && docker compose --profile tools pull -q'
  in_ct "Starting the apps" 'cd /opt/arr && docker compose up -d --remove-orphans'   # also removes the container gateway of an earlier version
  for app in "Radarr 7878" "Sonarr 8989" "Lidarr 8686" "Prowlarr 9696" "Bazarr 6767"; do
    set -- $app
    spin "$(t 'Waiting for %s to answer (the first start prepares its files)' "$1")" \
      bash -c 'for _ in $(seq 1 120); do curl -s -m 3 -o /dev/null "http://$1:$2/" 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$ip" "$2" ||
      fail "$(t 'Does not answer: %s at port %s. Look at: incus exec %s -- docker compose -f /opt/arr/docker-compose.yml logs --tail 50' "$1" "$2" "$ct")"
  done
fi

step "Settings"
# Through the apps' own API (Radarr and Sonarr, v3): Recycling Bin (a deleted or replaced file waits 7 days) and, when a
# SABnzbd client exists, "Remove Completed". Run the recipe again after adding the SABnzbd client by hand.
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no settings written"
else
  for app in "Radarr radarr 7878" "Sonarr sonarr 8989"; do
    set -- $app
    akey=$(incus exec "$ct" -- sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "/opt/arr/$2/config.xml" </dev/null 2>/dev/null | head -n1 || true)
    if [ -z "$akey" ]; then warn "$(t '%s: no API key found yet, settings not written (run the recipe again)' "$1")"; continue; fi
    res=$(bash "$(dirname "$0")/arr-tune.sh" "$ip" "$3" "$akey" /media/downloads/recycle 7 2>/dev/null || true)
    case "$res" in *recycle=set*|*recycle=same*) ok "$(t '%s: Recycling Bin /media/downloads/recycle, emptied after 7 days' "$1")" ;; *) warn "$(t '%s: Recycling Bin not set. Click: Settings -> Media Management -> Recycling Bin' "$1")" ;; esac
    case "$res" in
      *client=set*|*client=same*) ok "$(t '%s: SABnzbd client removes completed downloads' "$1")" ;;
      *client=none*) note "$(t '%s: no SABnzbd client yet; add it (step 3 below), then run this recipe again for Remove Completed' "$1")" ;;
      *) warn "$(t '%s: Remove Completed not set. Click: Settings -> Download Clients -> SABnzbd -> Remove Completed' "$1")" ;;
    esac
  done
  if incus info jellyfin >/dev/null 2>&1; then
    note "$(t 'Jellyfin: Radarr/Sonarr -> Settings -> Connect -> + -> Emby/Jellyfin: host, port 8096, API key (Jellyfin: Dashboard -> API Keys), tick Update Library. Not set by the recipe: the key needs a Jellyfin login')"
  fi
fi

step "Backup"
# The apps keep SQLite databases, which must not be copied while they are written. The dump goes to
# /var/backups/hs/arr (the files of the apps themselves are in the backup too); the posters/fanart cache
# (MediaCover) is large and gets fetched again, but it is in the backup as well.
install_dump_tool sqlite
# the standard dump (hs-dump): every database below /opt/arr goes to /var/backups/hs/arr/; older installs had their own script and /opt/arr/_dump
in_ct "Removing the old dump script" 'rm -rf /usr/local/sbin/hs-arr-dump /opt/arr/_dump'
media_backup "/usr/local/sbin/hs-dump sqlite-tree arr /opt/arr"
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

media_ntfy

step "Duplicates"
dedupe_line=""
if [ "$DEDUPE" = yes ]; then
  in_ct "Installing ffprobe and Python" '$1 update -qq && $1 install -y -qq --no-install-recommends ffmpeg python3-minimal ca-certificates' "$apt_quick"
  spin "Copying the programs" bash -c 'incus exec "$2" -- mkdir -p /opt/arr/dedupe /usr/local/lib/hs &&
    incus file push -q --mode 0755 "$1/hs-arr-dedupe.py" "$3/files/hs-media-notify.py" "$2/usr/local/lib/hs/"' _ "$(dirname "$0")" "$ct" "$scripts/recipes"
  media_notify_conf "$ct" /usr/local/lib/hs
  in_ct "Setting up the nightly job" 'chown -R "$1:$2" /opt/arr/dedupe
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
  note "Skipped: no duplicate cleanup (hs recipe arr --ask turns it on)"
fi

# Each app is a service of its own (http://sonarr.<local domain> with the capability gateway, its dashboard tile); the container "arr" has no
# service. A second arr container (--name) would overwrite these descriptors: it declares none.
if [ -z "${RECIPE_NAME:-}" ]; then
  declare_service radarr Radarr radarr never-public Media "Films: searches, downloads and files them" 7878
  declare_service sonarr Sonarr sonarr never-public Media "Series: searches, downloads and files them" 8989
  declare_service lidarr Lidarr lidarr never-public Media "Music: searches, downloads and files it" 8686
  declare_service prowlarr Prowlarr prowlarr never-public Media "The indexers for Radarr, Sonarr and Lidarr" 9696
  declare_service bazarr Bazarr bazarr never-public Media "Subtitles for films and series" 6767
  [ "$MAINTAINERR" != yes ] || declare_service maintainerr Maintainerr maintainerr never-public Media "Cleans up unwatched media by your own rules" 6246
fi

recipe_facts
kv "Radarr" "http://$ip:7878"
kv "Sonarr" "http://$ip:8989"
kv "Lidarr" "http://$ip:8686"
kv "Prowlarr" "http://$ip:9696"
kv "Bazarr" "http://$ip:6767"
[ "$MAINTAINERR" != yes ] || kv "Maintainerr" "http://$ip:6246"
box <<DONE
$(say "No Zoraxy rule for any of these pages. The few clicks that cannot wait:")
$(say "1. Radarr and Sonarr: Settings -> Media Management -> Root Folder:  /media/movies  and  /media/series  (Lidarr: /media/music)")
$(say "2. Prowlarr: add your indexer, then Settings -> Apps: connect Radarr, Sonarr and Lidarr (the key is in each app: Settings -> General)")
$(say "3. Radarr, Sonarr and Lidarr: Settings -> Download Clients -> SABnzbd (hs recipe sabnzbd), category  movies  /  tv  (Lidarr: audio)")
$(t 'Push messages (Settings -> Connect -> ntfy):  server %s   topic %s' "$ntfy_server" "$ntfy_topic")
$dedupe_line
$(docs_hint arr)
DONE
