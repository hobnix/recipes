#!/usr/bin/env bash
# recipe: Tdarr: converts the films once, so Jellyfin starts them at once (extra AC3 audio, old formats to H.264)
# recipe.de: Tdarr: wandelt die Filme einmalig um, damit Jellyfin sie sofort startet (zusätzliche AC3-Tonspur, alte Formate zu H.264)
# kind: generic
# needs: docker share
# uses: gpu
set -euo pipefail

# What it does: creates the container "tdarr" with Docker inside and runs Tdarr
# (server and one worker in one image) from its makers.
#   films            the share "media" (the one of the Jellyfin recipe), mounted
#                    READ-WRITE at /media with a user "tdarr" mapped 1:1, so the
#                    files stay adminuser's on disk. Jellyfin keeps only reading.
#   rules            one Tdarr plugin of this server, "Homeserver: make it easy for
#                    Jellyfin" (packages/tdarr/Tdarr_Plugin_hs_Jellyfin_Friendly.js):
#                    - a language whose audio is only TrueHD / DTS gets an extra AC3
#                      track, put first and marked default; the original stays behind it
#                    - the video is never touched (copied bit for bit), except formats
#                      Jellyfin can hardly show (DivX/Xvid, WMV, VC-1, MPEG-1/2, H.264
#                      10-bit / 4:2:2): those become H.264 at high quality
#                    - avi / ts / wmv ... become mkv without converting
#                    - before a file is changed, a hard link of the original is kept in
#                      /media/_tdarr-originals (same path); no link, no change
#   work files       /temp in the container (SSD pool): a film is written there first
# The libraries (which folders, the plugin, the night hours) are set up once in
# Tdarr's web page: the closing text lists the clicks. Tdarr's page has no login:
# it is an admin page and must never get a Zoraxy rule.
# Graphics card (optional, only asked when the server has an NVIDIA card): only the
# rare video conversion uses it (NVENC); audio and the usual remux run on the CPU.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# RECIPE_SKIP_STORAGE=1 (films stay in the container) RECIPE_SKIP_PULL=1 (no download
# of the image, no start: only the files are written) RECIPE_GPU=yes|no.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-tdarr}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the films (asks for its name, default media) READ-WRITE at /media"
  say "  install Docker inside and start Tdarr (server and one worker, about 1 GB to download)"
  say "  install the Tdarr plugin of this server (extra AC3 track, old formats to H.264, hard link of every original)"
  say "  if the server has an NVIDIA card (and you say yes): pass it into the container for the rare video conversion"
  exit 0
fi

port_setting "Tdarr" 8265
setting SHARE "Name of the share with the films (the one Jellyfin reads, under /bulk/shares)" media media "$a_name"
share=$SHARE
if [ -n "$(incus query /1.0/resources 2>/dev/null | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty' 2>/dev/null)" ]; then
  setting GPU "Use the NVIDIA graphics card when a video has to be converted? yes or no" yes no "yes|no"
else
  GPU=no
fi
ensure_container "$ct" 4096 --docker
fixed_address "$ct"
wait_internet "$ct"

step "User for the files"
# Tdarr's user becomes the owner as far as the container can tell (the share is mapped 1:1 to it);
# on disk the files stay adminuser's, so Samba and Jellyfin see no change
incus exec "$ct" -- sh -c 'id tdarr >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin tdarr' </dev/null
ids=$(incus exec "$ct" -- sh -c 'echo "$(id -u tdarr):$(id -g tdarr)"' </dev/null)
ok "$(t "User 'tdarr' (%s)" "$ids")"

step "Storage for the films"
if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE): the films stay inside the container"
  incus exec "$ct" -- sh -c 'mkdir -p /media/movies /media/series; chown -R tdarr: /media' </dev/null
elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/media")] | length')" != 0 ]; then
  ok "/media is mounted already"
else
  spin "$(t "Mounting the share '%s' at /media (read and write)" "$share")" \
    bash "$scripts/manage-ct.sh" "$ct" --add-storage shares "$share" /media --as "$ids"
fi
spin "Waiting for the container" bash -c "$wait_address" _ "$ct" "" 30      # the mount may have restarted it
ip=$(address "$ct")
incus exec "$ct" -- su -s /bin/sh tdarr -c 'touch /media/.hs-write-test && rm /media/.hs-write-test' </dev/null 2>/dev/null ||
  fail "$(t "Tdarr can't write to /media. Look at the storage of '%s' in: hs ct list" "$ct")"

step "Backup of the originals"
# The plugin keeps every original as a hard link under /media/_tdarr-originals (Tdarr writes a
# new file and removes the old name, the data of the old one stays in the link). That needs links
# between two folders of the share to work; check it with a real try.
if incus exec "$ct" -- su -s /bin/sh tdarr -c '
    set -e
    mkdir -p /media/movies /media/_tdarr-originals/movies
    echo test > /media/movies/.hs-link-test
    ln /media/movies/.hs-link-test /media/_tdarr-originals/movies/.hs-link-test
    [ "$(stat -c %i /media/movies/.hs-link-test)" = "$(stat -c %i /media/_tdarr-originals/movies/.hs-link-test)" ]
    rm -f /media/movies/.hs-link-test /media/_tdarr-originals/movies/.hs-link-test' </dev/null 2>/dev/null; then
  ok "Hard links work: originals are kept in /media/_tdarr-originals"
else
  incus exec "$ct" -- su -s /bin/sh tdarr -c 'rm -f /media/movies/.hs-link-test /media/_tdarr-originals/movies/.hs-link-test' </dev/null 2>/dev/null || true
  warn "Hard links do not work on this storage. The plugin then leaves every film alone (no backup, no change)."
fi

# the card into the container (before Docker: this restarts the container)
gpu_in=false
if [ "$GPU" = yes ]; then
  step "NVIDIA graphics card"
  if [ "$(incus config get "$ct" nvidia.runtime)" = true ] && incus config device get "$ct" gpu type >/dev/null 2>&1; then
    ok "passed in already"
    gpu_in=true
  elif nvidia_gpu "$ct"; then
    ok "$(t "'%s' can see the NVIDIA card" "$ct")"
    gpu_in=true
  else
    warn "The NVIDIA card could not be passed in. Videos are converted on the CPU; try again with: hs recipe tdarr --ask"
  fi
fi

install_docker

if $gpu_in; then
  nvidia_docker || { gpu_in=false; warn "Docker can't use the NVIDIA card. Videos are converted on the CPU; try again with: hs recipe tdarr --ask"; }
fi
if $gpu_in; then GPU=yes; else GPU=no; fi

step "Tdarr"
# docker-compose.yml is written again at every run (port, card); Tdarr's own data stays in server/ and configs/
compose='mkdir -p /opt/tdarr/server /opt/tdarr/configs /opt/tdarr/logs /temp
  {
    echo "services:"
    echo "  tdarr:"
    echo "    image: ghcr.io/haveagitgat/tdarr:latest"
    echo "    container_name: tdarr"
    echo "    restart: unless-stopped"
    echo "    ports:"
    echo "      - \"$1:8265\""
    echo "    environment:"
    echo "      - TZ=$2"
    echo "      - PUID=$3"
    echo "      - PGID=$4"
    echo "      - UMASK_SET=002"
    echo "      - serverIP=0.0.0.0"
    echo "      - serverPort=8266"
    echo "      - webUIPort=8265"
    echo "      - internalNode=true"
    echo "      - inContainer=true"
    echo "      - nodeName=hs-node"
    echo "      - NVIDIA_DRIVER_CAPABILITIES=all"
    echo "      - NVIDIA_VISIBLE_DEVICES=all"
    echo "    volumes:"
    echo "      - /opt/tdarr/server:/app/server"
    echo "      - /opt/tdarr/configs:/app/configs"
    echo "      - /opt/tdarr/logs:/app/logs"
    echo "      - /temp:/temp"
    echo "      - /media:/media"
    if [ "$5" = yes ]; then
      printf "    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n"
    fi
  } > /opt/tdarr/docker-compose.yml.new
  mv /opt/tdarr/docker-compose.yml.new /opt/tdarr/docker-compose.yml
  chown -R "$3:$4" /opt/tdarr/server /opt/tdarr/configs /opt/tdarr/logs /temp
  cd /opt/tdarr && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings (port, user, graphics card)" "$compose" "$PORT" "$tz" "${ids%%:*}" "${ids##*:}" "$GPU"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Tdarr not started"
else
  in_ct "Downloading Tdarr (about 1 GB, this takes a while)" 'cd /opt/tdarr && docker compose pull -q'
  in_ct "Starting Tdarr" 'cd /opt/tdarr && docker compose up -d --remove-orphans'
  wait_page Tdarr 'docker compose -f /opt/tdarr/docker-compose.yml logs --tail 50' --ok --tries 120
fi

step "Plugin of this server"
# Tdarr reads local plugins from server/Tdarr/Plugins/Local (in some versions Local/Classic).
# The folders exist after its first start; without a start (test) the flat one is made.
plugin=Tdarr_Plugin_hs_Jellyfin_Friendly.js
incus exec "$ct" -- bash -c '
  base=/opt/tdarr/server/Tdarr/Plugins/Local
  for _ in $(seq 1 30); do [ -d /opt/tdarr/server/Tdarr/Plugins ] && break; sleep 2; done
  if [ -d "$base/Classic" ]; then dest=$base/Classic; else dest=$base; fi
  mkdir -p "$dest"; echo "$dest" > /tmp/hs-tdarr-plugin-dir' </dev/null
dest=$(incus exec "$ct" -- cat /tmp/hs-tdarr-plugin-dir </dev/null)
incus file push -q --uid "${ids%%:*}" --gid "${ids##*:}" "$(dirname "$0")/$plugin" "$ct$dest/$plugin"
ok "$(t 'Plugin installed: %s' "${dest#/opt/tdarr/server/}/$plugin")"

step "Worker"
# A new Tdarr node starts with 0 workers of every kind and then leaves the queue alone for ever.
# Give it one CPU transcode worker (the plugin's audio work and remux run on the CPU), but only
# while all limits are still 0: a number you have set in Tdarr's page is never touched.
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): no Tdarr running"
else
  tdarr_api='curl -s -m 10 -X POST -H "Content-Type: application/json" localhost:8265/api/v2/cruddb --data-binary @-'
  node_doc() {   # the document of the node, empty until the node has registered
    printf '%s' '{"data":{"collection":"NodeJSONDB","mode":"getAll"}}' |
      incus exec "$ct" -- docker exec -i tdarr bash -c "$tdarr_api" 2>/dev/null |
      jq -c '.[] | select(._id == "hs-node")' 2>/dev/null || true
  }
  doc=""
  for _ in $(seq 1 30); do doc=$(node_doc); [ -n "$doc" ] && break; sleep 2; done
  if [ -z "$doc" ]; then
    warn "The Tdarr node has not registered yet. In Tdarr -> Nodes set the CPU transcode worker of 'hs-node' to 1, or nothing is processed."
  elif [ "$(jq -r '[.workerLimits[]] | add' <<<"$doc")" != 0 ]; then
    ok "The node has workers already"
  else
    jq -nc --argjson o "$(jq -c '.workerLimits.transcodecpu = 1' <<<"$doc")" \
      '{data: {collection: "NodeJSONDB", mode: "update", docID: "hs-node", obj: $o}}' |
      incus exec "$ct" -- docker exec -i tdarr bash -c "$tdarr_api" >/dev/null 2>&1 || true
    if [ "$(node_doc | jq -r '.workerLimits.transcodecpu // 0')" -ge 1 ] 2>/dev/null; then
      ok "One CPU transcode worker set for the node 'hs-node'"
    else
      warn "Could not set the worker. In Tdarr -> Nodes set the CPU transcode worker of 'hs-node' to 1, or nothing is processed."
    fi
  fi
fi

if [ "$GPU" = yes ]; then
  gpu_text=$(_tr "NVIDIA card in use for the rare video conversion.")
elif [ -n "$(incus query /1.0/resources 2>/dev/null | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty' 2>/dev/null)" ]; then
  gpu_text=$(_tr "not used, videos are converted on the CPU. To use the NVIDIA card: hs recipe tdarr --ask, answer yes.")
else
  gpu_text=$(_tr "no NVIDIA card in this server, videos are converted on the CPU.")
fi

declare_service tdarr Tdarr tdarr never-public Apps "Convert films for Jellyfin"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  Tdarr's page has no login. It is for you at home only: never give it a Zoraxy rule.")

$(say "Set it up once in the browser (Tdarr -> Libraries):")
$(say '  1. "Library +" -> name "Movies", source  /media/movies ; a second one  "Series" with  /media/series')
$(say "     (not /media/music, and never /media/_tdarr-originals).")
$(say '  2. Tab "Transcode options": transcode cache  /temp  ; leave "output folder" empty, so the')
$(say "     new file replaces the old one. In the plugin stack add the local plugin")
$(say '     "Homeserver: make it easy for Jellyfin" (search: Jellyfin) and nothing else.')
$(say '  3. Tab "Source" of the library: switch "Folder watch" and "Scan on start" on.')
$(say '     Back in the list of libraries: "Library options" -> "Scan (Fresh)".')
$(say '  4. Tdarr -> Nodes -> "hs-node": the recipe set 1 CPU transcode worker. Without a worker')
$(say '     (all numbers 0) nothing is processed. The node also has a schedule per hour for the night.')

$(t 'Graphics card: %s' "$gpu_text")
$(t 'Update Tdarr: hs recipe tdarr   (fetches the newest image and restarts it)')
$(docs_hint tdarr)
DONE
