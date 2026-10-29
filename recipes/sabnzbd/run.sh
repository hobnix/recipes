#!/usr/bin/env bash
# recipe: SABnzbd: the Usenet downloader that Radarr and Sonarr send their downloads to
# recipe.de: SABnzbd: der Usenet-Downloader, an den Radarr und Sonarr ihre Downloads schicken
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "sabnzbd" with Docker inside and runs SABnzbd (linuxserver.io image).
#   downloads    unpacked into /media/downloads/usenet/complete on the share "media" (the same path the recipe
#                "arr" uses, so Radarr and Sonarr move a finished download into the library by a hard link).
#                A user "sabnzbd" is mapped 1:1 to the share's owner: the files stay adminuser's on disk.
#   unfinished   /var/tmp/sab-incomplete inside the container (SSD pool): the heavy writing of loading, repairing
#                and unpacking stays off the big disks, and the backup skips /var/tmp.
#   settings     /opt/sabnzbd (the folders above are set through SABnzbd's API at the first run only). The
#                categories movies and tv are SABnzbd's own defaults, Radarr and Sonarr name them.
#   messages     SABnzbd's notification script (/opt/sabnzbd/config/scripts/hs-media-notify.py) posts "queued",
#                "finished", "failed" ... to ntfy and to Matrix (card service "SABnzbd"); set through the API once.
#   backup       `hs backup ct sabnzbd on` is switched on (the settings hold your news provider's login).
# The news provider (server, user, password) is typed in SABnzbd's own page: the recipe never asks for it.
# SABnzbd's page has an API key but should still never get a Zoraxy rule.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-sabnzbd}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 2048 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media"
  say "  start SABnzbd (asks for the port, default 80), finished downloads in /media/downloads/usenet/complete"
  say "  switch on SABnzbd's notification script: queued, finished and failed downloads go to ntfy and Matrix"
  say "  put the container in the nightly backup"
  exit 0
fi

port_setting "SABnzbd" 8080
setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
ensure_container "$ct" 2048 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
media_storage sabnzbd
install_docker

step "SABnzbd"
compose='mkdir -p /opt/sabnzbd /var/tmp/sab-incomplete
  cat > /opt/sabnzbd/docker-compose.yml.new <<YML
services:
  sabnzbd:
    image: lscr.io/linuxserver/sabnzbd:latest
    container_name: sabnzbd
    restart: unless-stopped
    ports: ["$4:8080"]
    environment:
      - TZ=$1
      - PUID=$2
      - PGID=$3
      - UMASK=002
    volumes: ["/opt/sabnzbd/config:/config", "/media:/media", "/var/tmp/sab-incomplete:/incomplete"]
YML
  mv /opt/sabnzbd/docker-compose.yml.new /opt/sabnzbd/docker-compose.yml
  mkdir -p /opt/sabnzbd/config
  chown -R "$2:$3" /opt/sabnzbd /var/tmp/sab-incomplete
  cd /opt/sabnzbd && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings (port, user)" "$compose" "$tz" "${ids%%:*}" "${ids##*:}" "$PORT"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, SABnzbd not started"
else
  in_ct "Downloading SABnzbd" 'cd /opt/sabnzbd && docker compose pull -q'
  in_ct "Starting SABnzbd" 'cd /opt/sabnzbd && docker compose up -d --remove-orphans'
  wait_page SABnzbd "docker compose -f /opt/sabnzbd/docker-compose.yml logs --tail 50"

  step "Folders"
  # The two folders are set once, through the API, at the first run (marker file); after that a folder
  # you have changed yourself is never touched.
  if incus exec "$ct" -- bash -c '
      ini=/opt/sabnzbd/config/sabnzbd.ini
      for _ in $(seq 1 30); do [ -s "$ini" ] && break; sleep 2; done
      key=$(sed -n "s/^api_key *= *//p" "$ini" | head -n1)
      [ -n "$key" ] || exit 1
      api="http://localhost:$1/api?apikey=$key&output=json&mode=set_config&section=misc"
      [ ! -e /opt/sabnzbd/.hs-folders-set ] || exit 0
      curl -fsS -m 10 -o /dev/null "$api&keyword=complete_dir&value=/media/downloads/usenet/complete"
      curl -fsS -m 10 -o /dev/null "$api&keyword=download_dir&value=/incomplete"
      touch /opt/sabnzbd/.hs-folders-set' bash "$PORT" </dev/null; then
    ok "Finished downloads go to /media/downloads/usenet/complete, unfinished ones to the SSD"
  else
    warn "Could not set the folders. In SABnzbd: Config -> Folders: Completed Download Folder  /media/downloads/usenet/complete  and Temporary  /incomplete."
  fi

  # SABnzbd refuses a name it does not know ("Hostname verification failed"); the IP always works. When the
  # container knows its full DNS name (hostname -f has a dot), it goes into host_whitelist once, at the first
  # run (marker file), so a list you edit yourself is never overwritten. No domain = nothing is changed.
  step "Host name"
  rc=0
  fqdn=$(incus exec "$ct" -- bash -c '
      [ ! -e /opt/sabnzbd/.hs-whitelist-set ] || exit 0
      name=$(hostname -f 2>/dev/null || true)
      case "$name" in *.*) ;; *) exit 0 ;; esac
      ini=/opt/sabnzbd/config/sabnzbd.ini
      key=$(sed -n "s/^api_key *= *//p" "$ini" | head -n1)
      [ -n "$key" ] || exit 1
      curl -fsS -m 10 -o /dev/null "http://localhost:$1/api?apikey=$key&output=json&mode=set_config&section=misc&keyword=host_whitelist&value=$name" || exit 1
      touch /opt/sabnzbd/.hs-whitelist-set
      echo "$name"' bash "$PORT" </dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    warn "Could not set host_whitelist. In SABnzbd: Config -> Special -> host_whitelist."
  elif [ -n "$fqdn" ]; then
    ok "$(t "SABnzbd accepts the name %s" "$fqdn")"
  else
    note "No domain name known for the container (or already set): SABnzbd answers on the address only. Other names: Config -> Special -> host_whitelist."
  fi
fi

step "Messages"
# SABnzbd runs the script in its own container (/config/scripts). The addresses sit next to it; the settings
# are made once, through the API (marker file), then checked in sabnzbd.ini: a name the version does not
# know would be accepted silently, so the check is what tells the truth.
scriptdir=/opt/sabnzbd/config/scripts
incus exec "$ct" -- mkdir -p "$scriptdir" </dev/null
incus file push -q --mode 0755 "$scripts/recipes/files/hs-media-notify.py" "$ct$scriptdir/hs-media-notify.py"
incus exec "$ct" -- chown -R "${ids%%:*}:${ids##*:}" "$scriptdir" </dev/null
media_notify_conf "$ct" "$scriptdir" lookup
incus exec "$ct" -- chown "${ids%%:*}:${ids##*:}" "$scriptdir/hs-media-notify.json" </dev/null
if [ -z "${RECIPE_SKIP_PULL:-}" ]; then
  if incus exec "$ct" -- bash -c '
      ini=/opt/sabnzbd/config/sabnzbd.ini
      key=$(sed -n "s/^api_key *= *//p" "$ini" | head -n1)
      [ -n "$key" ] || exit 1
      if [ ! -e /opt/sabnzbd/.hs-notify-set ]; then
        api="http://localhost:$1/api?apikey=$key&output=json&mode=set_config&section=misc"
        # only these event switches can be set through the API ("Config item does not exist" for disk_full, error, ...)
        for kv in script_dir=/config/scripts nscript_enable=1 nscript_script=hs-media-notify.py                   nscript_prio_download=1 nscript_prio_complete=1 nscript_prio_failed=1; do
          curl -fsS -m 10 -o /dev/null "$api&keyword=${kv%%=*}&value=${kv#*=}" || exit 1
        done
        sleep 3
        grep -Eq "^nscript_enable *= *1" "$ini" && grep -q "^nscript_script *= *hs-media-notify.py" "$ini" || exit 1
        touch /opt/sabnzbd/.hs-notify-set
      fi' bash "$PORT" </dev/null; then
    ok "SABnzbd posts queued, finished and failed downloads to ntfy and Matrix"
    note "Disk full, errors and warnings: tick them yourself in SABnzbd, Config -> Notifications (the API cannot set them)"
  else
    warn "Could not switch the messages on. In SABnzbd: Config -> Folders: Scripts Folder  /config/scripts, then Config -> Notifications -> Notification Script: script hs-media-notify.py, tick the events (Added NZB, Job finished, Failed)."
  fi
fi

step "Encrypted releases"
# An encrypted RAR can only be seen after its first part is downloaded. SABnzbd's default is to pause the job
# and wait for you; "abort" (pause_on_pwrar=2) fails it instead, so Radarr/Sonarr blacklist the release and
# search the next one by themselves. Set once (marker file), so a choice you make in the page stays.
if [ -z "${RECIPE_SKIP_PULL:-}" ]; then
  if incus exec "$ct" -- bash -c '
      ini=/opt/sabnzbd/config/sabnzbd.ini
      key=$(sed -n "s/^api_key *= *//p" "$ini" | head -n1)
      [ -n "$key" ] || exit 1
      [ ! -e /opt/sabnzbd/.hs-pwrar-set ] || exit 0
      curl -fsS -m 10 -o /dev/null "http://localhost:$1/api?apikey=$key&output=json&mode=set_config&section=misc&keyword=pause_on_pwrar&value=2" || exit 1
      touch /opt/sabnzbd/.hs-pwrar-set' bash "$PORT" </dev/null; then
    ok "Encrypted downloads are aborted, so Radarr and Sonarr try another release"
  else
    warn "Could not set it. In SABnzbd: Config -> Switches -> Action when encrypted RAR is downloaded: Abort."
  fi
fi

step "Backup"
media_backup ""
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

declare_service sabnzbd SABnzbd sabnzbd never-public Apps "Usenet downloads"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  No Zoraxy rule: it is for the home network only.")

$(say "The few clicks that cannot wait:")
$(say "  1. SABnzbd asks for your news provider the first time: server, port 563 with SSL, user, password,")
$(say "     about 20 connections. (The indexer goes into Prowlarr, not here.)")
$(say "  2. Radarr and Sonarr: Settings -> Download Clients -> add SABnzbd with this address and the API key")
$(say "     (SABnzbd: Config -> General), category  movies  /  tv.")
$(docs_hint arr)
DONE
