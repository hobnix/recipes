#!/usr/bin/env bash
# recipe: Jellyfin: watch your films, series and music in the browser, on the TV and on the phone
# recipe.de: Jellyfin: Filme, Serien und Musik im Browser, auf dem Fernseher und auf dem Handy ansehen
# kind: generic
# needs: share
# uses: gpu
# runs: lxc docker
set -euo pipefail

# What it does: creates the container "jellyfin" and installs Jellyfin from
# its own package source.
#   films, series, music   the share "media" on the bulk disks (/bulk/shares/media
#                          with the folders movies, series, music, anime/series,
#                          anime/movies), mounted at
#                          /media. You fill it over the network share, or other
#                          containers do; Jellyfin only reads it, so it can
#                          never delete or change a film.
#   Jellyfin's own data    (users, posters, what was watched) on the SSD pool,
#                          inside the container.
#   graphics card          the NVIDIA card, or else the chip built into the
#                          processor (Intel, AMD), is passed in, so videos can
#                          be converted for devices that need it without
#                          loading the CPU.
#   Abyss theme            optional (asked once): the dark "Abyss" look from
#                          github.com/AumGupta/abyss-jellyfin, added to the
#                          Custom CSS of Jellyfin's branding, plus its Spotlight banner
#                          (put back after every package update).
# Runs in one of two places (the question RUNS, `# runs: lxc docker`): the container "jellyfin" (above), or, when Docker is on
# (hs docker enable), as an app inside the container docker: compose project "jellyfin" in the share apps (recipes/jellyfin, data in
# its config and cache folders), the share "media" at /media of the container docker, mounted read-only into the app. A graphics
# card is used only when the container docker has one already (the recipe never adds a device there); else Jellyfin converts on the CPU.
# The Abyss theme is set up in the lxc mode only.
# Accounts are created in Jellyfin itself; the first visit sets up the admin.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-jellyfin}; app=$ct
folders="movies series music anime anime/series anime/movies"
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"
PORT=8096   # Jellyfin's own port (the lxc mode asks for it)

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  printf '%s\n' "$(t "  (docker mode: no container of its own: a compose project '%s' in the share apps (recipes/%s) inside the container docker, which must be on (hs docker enable); the share comes in with hs docker mount; a graphics card only when the container docker has one)" "$app" "$app")"
  say "  install Jellyfin inside"
  printf '%s\n' "$(t '  create a share for the media (asks for its name, default media) with the folders: %s' "$folders")"
  say "  mount it read-only at /media, readable for Jellyfin"
  say "  pass a graphics card into the container: the NVIDIA card, or else the processor's chip (Intel, AMD)"
  say "  optionally add the Abyss theme and its Spotlight banner to Jellyfin (asks; default no)"
  exit 0
fi

recipe_runtime lxc docker
if ! $RUNS_DOCKER; then
  port_setting "Jellyfin" 8096
fi
setting SHARE "Name of the share for films, series and music (under /bulk/shares)" media media "$a_name"
share=$SHARE
if $RUNS_DOCKER; then
  THEME=no
  note "The Abyss theme is set up in the lxc mode only; in Docker add it yourself under Dashboard -> Branding"
  child_port_free "$PORT" "$app"
else
  setting THEME "Install the Abyss theme for Jellyfin (github.com/AumGupta/abyss-jellyfin)? yes or no" no no "yes|no"
fi
abyss_css="https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@main/abyss.css"
if ! $RUNS_DOCKER; then
  ensure_container "$ct" 4096
  fixed_address "$ct"
fi
wait_internet "$ct"

# The steps of the lxc mode (package, storage, graphics card, network.xml, theme, systemctl) are guarded by `if ! $RUNS_DOCKER`;
# they are not indented, so the diff to the version before docker mode shows only the guards.
if ! $RUNS_DOCKER; then
step "Install Jellyfin"
if incus exec "$ct" -- sh -c 'dpkg-query -W jellyfin-server' >/dev/null 2>&1 </dev/null; then
  ok "installed already"
else
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing curl" '$1 install -y -qq curl ca-certificates gnupg' "$apt_quick"
  in_ct "Adding the Jellyfin package source" '
    mkdir -p /etc/apt/keyrings
    curl -fsSL -m 60 https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/jellyfin.gpg
    . /etc/os-release
    cat > /etc/apt/sources.list.d/jellyfin.sources <<SRC
Types: deb
URIs: https://repo.jellyfin.org/$ID
Suites: $VERSION_CODENAME
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/jellyfin.gpg
SRC
    $1 update -qq' "$apt_quick"
  in_ct "Installing Jellyfin (about 300 MB)" '$1 install -y -qq jellyfin' "$apt_quick"
fi
note "Jellyfin $(incus exec "$ct" -- dpkg-query -W -f '${Version}' jellyfin-server </dev/null)"
fi

step "Storage for films, series and music"
if $RUNS_DOCKER; then   # the user "media" of the container docker, the share read-write at /media of docker (Jellyfin gets it read-only below)
  media_storage jellyfin
elif [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE)"
  incus exec "$ct" -- sh -c "cd /media 2>/dev/null || mkdir -p /media; cd /media && mkdir -p $folders" </dev/null
elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/media")] | length')" != 0 ]; then
  ok "/media is mounted already"
else
  # Jellyfin's user becomes the owner as far as the container can tell, so it
  # can read every file whatever its permissions; on disk the files stay adminuser's
  ids=$(incus exec "$ct" -- sh -c 'echo "$(id -u jellyfin):$(id -g jellyfin)"' </dev/null)
  spin "$(t "Creating the share '%s' and mounting it read-only at /media" "$share")" \
    bash "$scripts/manage-ct.sh" "$ct" --add-storage shares "$share" /media --readonly --as "$ids"
fi
if [ -z "${RECIPE_SKIP_STORAGE:-}" ]; then
  # also on a re-run, so a folder added to the list later appears in a share that exists already
  for f in $folders; do
    [ -d "/bulk/shares/$share/$f" ] || install -d -o adminuser -g users -m 2775 "/bulk/shares/$share/$f"
  done
  ok "$(t 'Folders in the share: %s' "$folders")"
fi
if ! $RUNS_DOCKER; then
spin "Waiting for the container" bash -c "$wait_address" _ "$ct" "" 30      # the mount may have restarted it
ip=$(address "$ct")
incus exec "$ct" -- su -s /bin/sh jellyfin -c 'ls /media >/dev/null' </dev/null 2>/dev/null ||
  fail "$(t "Jellyfin can't read /media. Look at the storage of '%s' in: hs ct list" "$ct")"
fi

step "Graphics card"
# Converting a video for a device that can't play it as it is costs a lot of
# CPU; a graphics card does it far cheaper. First choice is the NVIDIA card,
# second the chip built into the processor (Intel, AMD), which Jellyfin's own
# ffmpeg supports without extra drivers.
ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg
gpu=""       # what Jellyfin has to be set to, for the closing text
nl=$'\n'; gpuenv=""; gpusvc=""
if $RUNS_DOCKER; then
  # Read only: the recipe never adds a device to the container docker. A card is used when it is there already.
  dri=$(incus exec docker -- sh -c 'for f in /dev/dri/renderD*; do [ -e "$f" ] && { stat -c %g "$f"; exit 0; }; done; exit 0' </dev/null || true)
  nv=no
  if [ "$(incus config get docker nvidia.runtime 2>/dev/null)" = true ] &&
     incus exec docker -- sh -c 'docker info --format "{{json .Runtimes}}" | grep -q nvidia' </dev/null >/dev/null 2>&1; then
    nv=yes
  fi
  if [ "$nv" = yes ]; then
    gpusvc="${nl}    runtime: nvidia"
    gpuenv="${nl}      - NVIDIA_VISIBLE_DEVICES=all${nl}      - NVIDIA_DRIVER_CAPABILITIES=all"
    ok "The container docker has an NVIDIA card: Jellyfin gets it"
  elif [ -n "$dri" ]; then
    gpusvc="${nl}    devices: [\"/dev/dri:/dev/dri\"]${nl}    group_add: [\"$dri\"]"
    ok "The container docker has a graphics chip (/dev/dri): Jellyfin gets it"
  else
    warn "The container docker has no graphics card: Jellyfin converts videos on the CPU. Hardware transcoding: run this recipe with RUNS=lxc (a container of its own)."
  fi
else
# let the card encode a second of video, as the user Jellyfin runs as
try_encode() {   # try_encode <encoder options>
  incus exec "$ct" -- su -s /bin/sh jellyfin -c \
    "$ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=1:size=1280x720:rate=30 $1 -f null -" </dev/null >/dev/null 2>&1
}
uses_nvidia() { [ "$(incus config get "$ct" nvidia.runtime)" = true ]; }
if incus config device get "$ct" gpu type >/dev/null 2>&1; then
  ok "passed in already"
elif nvidia_gpu "$ct"; then
  :
else
  pci=$(incus query /1.0/resources | jq -r '[.gpu.cards[] | select(.driver == "i915" or .driver == "xe" or .driver == "amdgpu")][0].pci_address // empty')
  if [ -z "$pci" ]; then
    note "No usable graphics card found; Jellyfin converts videos on the CPU."
  else
    render=$(incus exec "$ct" -- getent group render </dev/null | cut -d: -f3)
    incus config device add "$ct" gpu gpu "pci=$pci" "gid=${render:-0}" mode=0660 >/dev/null
  fi
fi
if incus config device get "$ct" gpu type >/dev/null 2>&1; then
  incus exec "$ct" -- usermod -aG render,video jellyfin </dev/null
  if uses_nvidia; then
    if try_encode "-c:v h264_nvenc"; then
      gpu="Nvidia NVENC"
      ok "$(t 'Jellyfin can use the NVIDIA card (%s)' "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)")"
    fi
  elif try_encode "-init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va -vf format=nv12,hwupload -c:v h264_vaapi"; then
    gpu="Intel QuickSync (QSV)"
    ok "Jellyfin can use the graphics chip of the processor"
  fi
  [ -n "$gpu" ] || warn "The graphics card is passed in, but a test encode failed; Jellyfin may fall back to the CPU."
fi
fi

if $RUNS_DOCKER; then
  step "Jellyfin"
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
  dir=$APP_DIR
  in_ct "Preparing the folders" 'mkdir -p "$1/config" "$1/cache" && chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
  # the share is read-write at /media of docker (Radarr and the others write there); Jellyfin only reads it
  child_compose "$app" <<YML
services:
  $app:
    image: jellyfin/jellyfin:latest
    container_name: $app
    restart: unless-stopped
    user: "${ids%%:*}:${ids##*:}"
    ports: ["8096:8096"]
    environment:
      - TZ=$tz$gpuenv
    volumes: ["$dir/config:/config", "$dir/cache:/cache", "/media:/media:ro"]$gpusvc
YML
  in_ct "Setting the owner of the files" 'chown -R "$2:$3" "$1"' "$dir" "${ids%%:*}" "${ids##*:}"
  if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
    note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Jellyfin not started"
  else
    in_ct "Downloading Jellyfin" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$dir"
    spin "Starting Jellyfin" child_up "$app"
    wait_page Jellyfin "docker compose -p $app -f $dir/docker-compose.yml logs --tail 50" --path /health --ok --plain --tries 60
    if [ "$nv" = yes ] || [ -n "$dri" ]; then
      try_encode_docker() {   # try_encode_docker <encoder options>: let the card encode a second of video inside the app
        incus exec docker -- docker exec "$app" "$ffmpeg" -hide_banner -loglevel error -f lavfi -i testsrc=duration=1:size=1280x720:rate=30 $1 -f null - </dev/null >/dev/null 2>&1
      }
      if [ "$nv" = yes ]; then
        if try_encode_docker "-c:v h264_nvenc"; then
          gpu="Nvidia NVENC"
          ok "Jellyfin can use the NVIDIA card"
        fi
      elif try_encode_docker "-init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va -vf format=nv12,hwupload -c:v h264_vaapi"; then
        gpu="Intel QuickSync (QSV)"
        ok "Jellyfin can use the graphics chip of the processor"
      fi
      [ -n "$gpu" ] || warn "The graphics card is passed in, but a test encode failed; Jellyfin may fall back to the CPU."
    fi
  fi

  step "Backup"
  # Jellyfin keeps SQLite databases (and more files) in its config folder; the dump goes to /var/backups/hs/jellyfin
  install_dump_tool sqlite
  media_backup "/usr/local/sbin/hs-dump sqlite-tree $app $APP_DIR/config"
fi

if ! $RUNS_DOCKER; then
step "Start"
low_ports
# Jellyfin keeps its port in network.xml; what is missing there gets its usual value
in_ct "$(t 'Setting the port of the web page to %s' "$PORT")" '
  f=/etc/jellyfin/network.xml
  if [ -s "$f" ] && grep -q "<InternalHttpPort>" "$f"; then
    sed -i -E "s|<InternalHttpPort>[0-9]+</InternalHttpPort>|<InternalHttpPort>$1</InternalHttpPort>|; s|<PublicHttpPort>[0-9]+</PublicHttpPort>|<PublicHttpPort>$1</PublicHttpPort>|" "$f"
  else
    mkdir -p /etc/jellyfin
    printf "%s\n" "<?xml version=\"1.0\" encoding=\"utf-8\"?>" "<NetworkConfiguration xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">" "  <InternalHttpPort>$1</InternalHttpPort>" "  <PublicHttpPort>$1</PublicHttpPort>" "</NetworkConfiguration>" > "$f"
    chown jellyfin: "$f" 2>/dev/null || true
  fi' "$PORT"
if [ "$THEME" = yes ]; then
  # Dashboard -> Branding -> Custom CSS lives in branding.xml; an import already there stays, other CSS is kept
  in_ct "Adding the Abyss theme to the Custom CSS" '
    f=/etc/jellyfin/branding.xml
    imp="@import url('"'"'$1'"'"');"
    if [ -s "$f" ] && grep -qF "$1" "$f"; then
      :
    elif [ -s "$f" ] && grep -q "<CustomCss />" "$f"; then
      sed -i "s|<CustomCss />|<CustomCss>$imp</CustomCss>|" "$f"
    elif [ -s "$f" ] && grep -q "<CustomCss>" "$f"; then
      sed -i "s|<CustomCss>|<CustomCss>$imp\n|" "$f"
    else
      mkdir -p /etc/jellyfin
      printf "%s\n" "<?xml version=\"1.0\" encoding=\"utf-8\"?>" "<BrandingOptions xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">" "  <CustomCss>$imp</CustomCss>" "</BrandingOptions>" > "$f"
      chown jellyfin: "$f" 2>/dev/null || true
    fi' "$abyss_css"
  # Spotlight (the big featured banner) is not CSS: three files and one script tag in Jellyfin's own index.html.
  # A package update replaces index.html, so a small script puts the tag back after every apt run.
  incus exec "$ct" -- sh -c 'cat > /usr/local/sbin/abyss-spotlight && chmod 755 /usr/local/sbin/abyss-spotlight' <<'SPOT'
#!/bin/sh
# Puts the Abyss Spotlight into Jellyfin's web files. --update downloads the files again.
web=/usr/share/jellyfin/web
base=https://raw.githubusercontent.com/AumGupta/abyss-jellyfin/main/scripts/spotlight
[ -f "$web/index.html" ] || exit 0
mkdir -p "$web/ui"
for f in spotlight.html spotlight.css spotlight-loader.js; do
  if [ "${1:-}" = --update ] || [ ! -s "$web/ui/$f" ]; then
    curl -fsSL -m 60 -o "$web/ui/$f.new" "$base/$f" && mv "$web/ui/$f.new" "$web/ui/$f" || { rm -f "$web/ui/$f.new"; echo "abyss-spotlight: could not download $f" >&2; exit 1; }
  fi
done
grep -q data-abyss-spotlight "$web/index.html" ||
  sed -i 's|</body>|<script src="ui/spotlight-loader.js" data-abyss-spotlight></script></body>|' "$web/index.html"
SPOT
  incus exec "$ct" -- sh -c 'printf "%s
" "DPkg::Post-Invoke { \"/usr/local/sbin/abyss-spotlight || true\"; };" > /etc/apt/apt.conf.d/99-abyss-spotlight' </dev/null
  in_ct "Adding the Abyss Spotlight to Jellyfin's web files" '/usr/local/sbin/abyss-spotlight --update && grep -q data-abyss-spotlight /usr/share/jellyfin/web/index.html'
elif incus exec "$ct" -- sh -c 'test -e /usr/local/sbin/abyss-spotlight || grep -qs abyss-jellyfin /etc/jellyfin/branding.xml' </dev/null; then
  # answered no after yes earlier: take the theme out again, other Custom CSS stays
  in_ct "Removing the Abyss theme and its Spotlight" '
    f=/etc/jellyfin/branding.xml
    if [ -s "$f" ]; then
      sed -i -E "s|@import url\(.https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin[^)]*\);||; s|<CustomCss>[[:space:]]*</CustomCss>|<CustomCss />|" "$f"
    fi
    web=/usr/share/jellyfin/web
    [ ! -f "$web/index.html" ] || sed -i "s|<script src=\"ui/spotlight-loader.js\" data-abyss-spotlight></script>||" "$web/index.html"
    rm -f "$web/ui/spotlight.html" "$web/ui/spotlight.css" "$web/ui/spotlight-loader.js"
    rmdir "$web/ui" 2>/dev/null || true
    rm -f /usr/local/sbin/abyss-spotlight /etc/apt/apt.conf.d/99-abyss-spotlight'
fi
in_ct "Starting Jellyfin with the system" 'systemctl enable -q jellyfin; systemctl restart jellyfin'
wait_page Jellyfin 'journalctl -u jellyfin' --path /health --ok --plain --tries 60
fi

recipe_facts web
# the tile shows how many streams play right now; Jellyfin's /Sessions needs an API key an admin makes (hs services key jellyfin)
SERVICE_STATS="http-json|Streams|/Sessions||count|/NowPlayingItem|stat-$app|mediabrowser||"
if $RUNS_DOCKER; then   # ct is docker here: the service is the app (RECIPE_NAME= keeps declare_service from renaming it to "docker")
  RECIPE_NAME= declare_service "$app" Jellyfin jellyfin private-ok Apps "Films, series, music"
else
  declare_service jellyfin Jellyfin jellyfin private-ok Apps "Films, series, music"
fi
unc="\\\\$(hostname)\\$share"
kv "Share" "$unc"
kv "Folders" "$folders"
box <<DONE
$(say "1. The first visit asks for the language and creates the admin account.")
$(say '2. "Add Media Library", one per kind: Movies /media/movies, Shows /media/series, Music /media/music, Anime shows /media/anime/series, Anime movies /media/anime/movies.')
$([ -z "$gpu" ] || t '3. Dashboard -> Playback -> Transcoding: hardware acceleration "%s".' "$gpu")
$([ "$THEME" != yes ] || say '4. Abyss: Settings -> Display -> Theme "Dark" (per user), then reload the page with Ctrl+F5.')
$(t '5. Dashboard tile "Streams": Dashboard -> API Keys -> add a key, then run: hs services key %s (the key is asked hidden).' "$app")
$(docs_hint containers-and-apps)
DONE
