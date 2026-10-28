#!/usr/bin/env bash
# recipe: Jellyfin: watch your films, series and music in the browser, on the TV and on the phone
# recipe.de: Jellyfin: Filme, Serien und Musik im Browser, auf dem Fernseher und auf dem Handy ansehen
# kind: generic
# needs: share
# uses: gpu
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
# Accounts are created in Jellyfin itself; the first visit sets up the admin.
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-jellyfin}
folders="movies series music anime anime/series anime/movies"
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (4096 MB RAM limit) unless it exists, with a fixed address if UniFi is connected (hs net setup)" "$ct")"
  say "  install Jellyfin inside"
  printf '%s\n' "$(t '  create a share for the media (asks for its name, default media) with the folders: %s' "$folders")"
  say "  mount it read-only at /media, readable for Jellyfin"
  say "  pass a graphics card into the container: the NVIDIA card, or else the processor's chip (Intel, AMD)"
  say "  optionally add the Abyss theme and its Spotlight banner to Jellyfin (asks; default no)"
  exit 0
fi

port_setting "Jellyfin" 8096
setting SHARE "Name of the share for films, series and music (under /bulk/shares)" media media "$a_name"
share=$SHARE
setting THEME "Install the Abyss theme for Jellyfin (github.com/AumGupta/abyss-jellyfin)? yes or no" no no "yes|no"
abyss_css="https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@main/abyss.css"
ensure_container "$ct" 4096
fixed_address "$ct"
wait_internet "$ct"

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

step "Storage for films, series and music"
if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
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
spin "Waiting for the container" bash -c "$wait_address" _ "$ct" "" 30      # the mount may have restarted it
ip=$(address "$ct")
incus exec "$ct" -- su -s /bin/sh jellyfin -c 'ls /media >/dev/null' </dev/null 2>/dev/null ||
  fail "$(t "Jellyfin can't read /media. Look at the storage of '%s' in: hs ct list" "$ct")"

step "Graphics card"
# Converting a video for a device that can't play it as it is costs a lot of
# CPU; a graphics card does it far cheaper. First choice is the NVIDIA card,
# second the chip built into the processor (Intel, AMD), which Jellyfin's own
# ffmpeg supports without extra drivers.
ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg
# let the card encode a second of video, as the user Jellyfin runs as
try_encode() {   # try_encode <encoder options>
  incus exec "$ct" -- su -s /bin/sh jellyfin -c \
    "$ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=1:size=1280x720:rate=30 $1 -f null -" </dev/null >/dev/null 2>&1
}
gpu=""       # what Jellyfin has to be set to, for the closing text
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

recipe_facts web
declare_service jellyfin Jellyfin jellyfin private-ok Apps "Films, series, music"
unc="\\\\$(hostname)\\$share"
kv "Share" "$unc"
kv "Folders" "$folders"
box <<DONE
$(say "1. The first visit asks for the language and creates the admin account.")
$(say '2. "Add Media Library", one per kind: Movies /media/movies, Shows /media/series, Music /media/music, Anime shows /media/anime/series, Anime movies /media/anime/movies.')
$([ -z "$gpu" ] || t '3. Dashboard -> Playback -> Transcoding: hardware acceleration "%s".' "$gpu")
$([ "$THEME" != yes ] || say '4. Abyss: Settings -> Display -> Theme "Dark" (per user), then reload the page with Ctrl+F5.')
$(docs_hint containers-and-apps)
DONE
