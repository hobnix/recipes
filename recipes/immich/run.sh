#!/usr/bin/env bash
# recipe: Immich: your own photo and video library with phone backup, like Google Photos
# recipe.de: Immich: deine eigene Foto- und Videosammlung mit Handy-Sicherung, wie Google Fotos
# kind: generic
# needs: docker share
# uses: gpu
set -euo pipefail

# What it does: creates the container "immich" with Docker inside and runs
# Immich the way its makers ship it (their docker-compose.yml, four parts:
# server, machine learning, database, cache).
#   photos and videos   on the bulk disks: the folder /bulk/sensitive/immich,
#                       mounted at /mnt/immich. "sensitive" because Immich
#                       manages these files; over the network share they can
#                       be read, not changed.
#   database            on the SSD pool, inside the container (/opt/immich/postgres).
#                       Immich writes a dump of it into the photo folder every night.
# Users are created in Immich itself; the first visitor becomes its admin.
# Graphics card (optional, only asked when the server has an NVIDIA card; an
# install from before this question keeps the CPU until --ask): the card is
# passed into the container, Docker gets NVIDIA's container toolkit, and
# Immich's machine learning (smart search, faces) runs on it (image variant
# -cuda); video conversion (NVENC) can use it after one switch in Immich.
# Anything that fails there is a warning: Immich then runs on the CPU as before.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir>
# RECIPE_SKIP_STORAGE=1 (photos stay in the container) RECIPE_SKIP_PULL=1 (no
# download of the Immich images and no start: only the compose files are
# written and checked) RECIPE_GPU=yes|no (instead of the question).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-immich}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 6144 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  create a folder under /bulk/sensitive for the photos (asks for its name, default immich) and mount it at /mnt/immich"
  say "  install Docker inside and start Immich from its official docker-compose.yml (several GB to download)"
  say "  keep the database on the SSD pool (/opt/immich/postgres in the container)"
  say "  put the container in the nightly backup with a database dump"
  say "  if the server has an NVIDIA card (and you say yes): pass it into the container, install NVIDIA's container toolkit for Docker and run Immich's machine learning on it"
  exit 0
fi

port_setting "Immich" 2283
setting SHARE "Name of the folder for the photos (under /bulk/sensitive, also the share's name)" immich immich "$a_name"
share=$SHARE
# the question only exists when there is a card to use
if [ -n "$(incus query /1.0/resources 2>/dev/null | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty' 2>/dev/null)" ]; then
  setting GPU "Use the NVIDIA graphics card for Immich (smart search, faces, video conversion)? yes or no" yes no "yes|no"
else
  GPU=no
fi
ensure_container "$ct" 6144 --docker
fixed_address "$ct"
wait_internet "$ct"

step "Storage for the photos"
if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE): the photos stay inside the container"
  incus exec "$ct" -- mkdir -p /mnt/immich </dev/null
elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/mnt/immich")] | length')" != 0 ]; then
  ok "/mnt/immich is mounted already"
else
  spin "$(t 'Creating /bulk/sensitive/%s and mounting it at /mnt/immich' "$share")" \
    bash "$scripts/manage-ct.sh" "$ct" --add-storage sensitive "$share" /mnt/immich
fi
incus exec "$ct" -- sh -c 'touch /mnt/immich/.hs-write-test && rm /mnt/immich/.hs-write-test' </dev/null 2>/dev/null ||
  fail "$(t "The container can't write to /mnt/immich. Look at the storage of '%s' in: hs ct list" "$ct")"

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
    warn "The NVIDIA card could not be passed in. Immich runs on the CPU; try again with: hs recipe immich --ask"
  fi
fi

install_docker

if $gpu_in; then
  nvidia_docker || { gpu_in=false; warn "Docker can't use the NVIDIA card. Immich runs on the CPU; try again with: hs recipe immich --ask"; }
fi
if $gpu_in; then GPU=yes; else GPU=no; fi

step "Immich"
in_ct "Fetching Immich's docker-compose.yml" '
  mkdir -p /opt/immich && cd /opt/immich
  curl -fsSL -m 60 -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
  # the settings are written once: the database password in them must never change
  if [ ! -s .env ]; then
    curl -fsSL -m 60 -o .env.new https://github.com/immich-app/immich/releases/latest/download/example.env
    pw=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32 || true)
    sed -i -E \
      -e "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/mnt/immich|" \
      -e "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=/opt/immich/postgres|" \
      -e "s|^#? ?TZ=.*|TZ=$1|" \
      -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$pw|" .env.new
    grep -q "^UPLOAD_LOCATION=/mnt/immich$" .env.new && grep -q "^DB_PASSWORD=$pw$" .env.new
    chmod 600 .env.new && mv .env.new .env
  fi
  ' "$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)"

# Our changes to their file, in docker-compose.override.yml (written again at every run):
# the port of the web page, and with the card the -cuda variant of the machine learning
# plus the settings for video conversion, from the same Immich release.
override='cd /opt/immich
  {
    echo "services:"
    echo "  immich-server:"
    if [ "$2" = yes ]; then printf "    extends:\n      file: hwaccel.transcoding.yml\n      service: nvenc\n"; fi
    printf "    ports: !override\n      - \"%s:2283\"\n" "$1"
    if [ "$2" = yes ]; then
      ml=$(sed -n "s/^ *image: *\(.*immich-machine-learning:.*\)$/\1/p" docker-compose.yml | head -n1)
      [ -n "$ml" ]
      printf "  immich-machine-learning:\n    image: %s-cuda\n    extends:\n      file: hwaccel.ml.yml\n      service: cuda\n" "$ml"
    fi
  } > docker-compose.override.yml.new
  mv docker-compose.override.yml.new docker-compose.override.yml
  docker compose config -q'
if [ "$GPU" = yes ]; then
  base=https://github.com/immich-app/immich/releases/latest/download
  SPIN_SOFT=1 in_ct "Fetching the graphics card settings of Immich" \
    "cd /opt/immich && curl -fsSL -m 60 -o hwaccel.ml.yml.new $base/hwaccel.ml.yml && curl -fsSL -m 60 -o hwaccel.transcoding.yml.new $base/hwaccel.transcoding.yml && mv hwaccel.ml.yml.new hwaccel.ml.yml && mv hwaccel.transcoding.yml.new hwaccel.transcoding.yml" &&
    SPIN_SOFT=1 in_ct "Writing the settings (port, graphics card)" "$override" "$PORT" yes ||
    { GPU=no; warn "The graphics card settings of Immich could not be set up. Immich runs on the CPU."; }
fi
if [ "$GPU" != yes ]; then
  in_ct "Writing the settings (port)" "$override" "$PORT" no
fi
pull='cd /opt/immich && docker compose pull -q'
start='cd /opt/immich && docker compose up -d --remove-orphans'
if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Immich not started"
else
  if [ "$GPU" = yes ]; then
    # with the card; if that does not start, the same install on the CPU
    if ! { SPIN_SOFT=1 in_ct "Downloading Immich (several GB, this takes a while)" "$pull" &&
           SPIN_SOFT=1 in_ct "Starting Immich with the graphics card" "$start"; }; then
      GPU=no
      warn "Immich did not start with the graphics card. Switching to the CPU."
      in_ct "Writing the settings (port)" "$override" "$PORT" no
    fi
  fi
  if [ "$GPU" != yes ]; then
    in_ct "Downloading Immich (several GB, this takes a while)" "$pull"
    in_ct "Starting Immich" "$start"
  fi
  wait_page Immich 'docker compose -f /opt/immich/docker-compose.yml logs --tail 50' --path /api/server/ping --match pong --tries 150
  note "Immich $(curl -fsS -m 5 "$(web)/api/server/version" 2>/dev/null | jq -r '"\(.major).\(.minor).\(.patch)"' 2>/dev/null || _tr "is running")"
  if [ "$GPU" = yes ]; then
    if incus exec "$ct" -- docker exec immich_machine_learning test -e /dev/nvidia0 </dev/null 2>/dev/null; then
      ok "Immich's machine learning has the NVIDIA card"
    else
      warn "$(t 'The machine learning container does not show the card; it may be running on the CPU. Look at: incus exec %s -- docker logs immich_machine_learning' "$ct")"
    fi
  fi
fi

if [ "$GPU" = yes ]; then
  gpu_text="$(say 'NVIDIA card in use. Smart search and faces run on it now.')
$(say '  Video conversion needs one switch, once, in Immich: Administration -> Settings ->')
$(say '  Video Transcoding Settings -> Hardware Acceleration -> NVENC (Nvidia), save.')
$(say '  Turn it off again: hs recipe immich --ask, answer no.')"
elif [ -n "$(incus query /1.0/resources 2>/dev/null | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty' 2>/dev/null)" ]; then
  gpu_text="$(say 'not used, Immich runs on the CPU.')
$(say '  To use the NVIDIA card: hs recipe immich --ask, answer yes.')"
else
  gpu_text=$(_tr "no NVIDIA card in this server, Immich runs on the CPU.")
fi

step "Backup"
# the database runs in a Docker container of its own: a copy of its files while it runs is not safe, so a dump (hs-dump) is made right before each backup
install_dump_tool
backup_with_dump immich "/usr/local/sbin/hs-dump postgres-compose immich /opt/immich database postgres immich"
ok "$(t "'%s' is in the nightly backup with a database dump (hs backup ct %s off: take it out)" "$ct" "$ct")"

unc="\\\\$(hostname)\\$share"
recipe_facts web
declare_service immich Immich immich private-ok Apps "Photos and videos"
kv "Photos" "/bulk/sensitive/$share"
kv "Share" "$unc"
box <<DONE
$(say '1. "Getting Started": the first account you create becomes the admin (more people: Administration -> Users).')
$(t '2. Phone: install the app "Immich", server address  %s , log in, switch on the backup of the camera roll.' "$(web)")
$(say "   The phone must be in the home network or connected through Tailscale.")
$(t 'Graphics card: %s' "$gpu_text")
$(docs_hint containers-and-apps)
DONE
