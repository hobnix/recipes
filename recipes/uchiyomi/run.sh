#!/usr/bin/env bash
# recipe: Uchiyomi: a manga reader and downloader that watches for new chapters (webtoons and manhwa too)
# recipe.de: Uchiyomi: Manga-Leser und -Downloader, der nach neuen Kapiteln sucht (auch Webtoons und Manhwa)
# kind: generic
# needs: docker share
# uses: -
set -euo pipefail

# What it does: creates the container "uchiyomi" with Docker inside and runs Uchiyomi (uchiyomi.com, ghcr.io/angelosha/uchiyomi)
# with its two helpers, written the way its own docker-compose.yml has them: FlareSolverr (gets past the Cloudflare check
# of manga sites) and Suwayomi (runs the Mihon/Tachiyomi extensions). The database is inside the app container.
#   manga       the folder "manga" in the share "media" (/bulk/shares/media/manga, made by this recipe), mounted
#               with the share at /media; the library of Uchiyomi is /media/manga. Jellyfin sees it too
#               (the share is the same), but only Uchiyomi writes to it.
#   app data    /opt/uchiyomi (SSD pool): the compose file and the app's own backups (/opt/uchiyomi/backups);
#               `hs backup ct uchiyomi on` is switched on
# Zoraxy: no rule (the admin page and the sign-in are the whole app).
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_STORAGE=1 RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-uchiyomi}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
. "${HS_RECIPE_MEDIA:-$scripts/recipes/_media.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (Docker inside, 5120 MB RAM limit) unless it exists, with a fixed address (.20-.29) if UniFi is connected (hs net setup)" "$ct")"
  say "  mount the share for the media (asks for its name, default media) read and write at /media and create the folder manga in it"
  say "  start Uchiyomi with FlareSolverr and Suwayomi (asks for the port, default 80)"
  say "  put the container in the nightly backup"
  exit 0
fi

port_setting "Uchiyomi" 8080
setting SHARE "Name of the share for films, series and manga (under /bulk/shares)" media media "$a_name"
share=$SHARE
ensure_container "$ct" 5120 --docker
fixed_address "$ct" 20 29
wait_internet "$ct"
install_docker

step "User for the files"
user=uchiyomi
incus exec "$ct" -- sh -c "id $user >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin $user" </dev/null
ids=$(incus exec "$ct" -- sh -c "echo \"\$(id -u $user):\$(id -g $user)\"" </dev/null)
ok "$(t "User '%s' (%s)" "$user" "$ids")"

step "Storage for the manga"
if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
  note "skipped (RECIPE_SKIP_STORAGE): the files stay inside the container"
  incus exec "$ct" -- sh -c "mkdir -p /media/manga; chown $user: /media/manga" </dev/null
elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/media")] | length')" != 0 ]; then
  ok "/media is mounted already"
else
  spin "$(t "Mounting the share '%s' at /media (read and write)" "$share")" \
    bash "$scripts/manage-ct.sh" "$ct" --add-storage shares "$share" /media --as "$ids"
fi
if [ -z "${RECIPE_SKIP_STORAGE:-}" ]; then
  # also on a re-run; the folder belongs to adminuser like everything in the share
  [ -d "/bulk/shares/$share/manga" ] || install -d -o adminuser -g users -m 2775 "/bulk/shares/$share/manga"
  ok "$(t "Folder 'manga' in the share '%s'" "$share")"
fi
spin "Waiting for the container" bash -c "$wait_address" _ "$ct" "" 30      # the mount may have restarted it
ip=$(address "$ct")
incus exec "$ct" -- su -s /bin/sh "$user" -c 'mkdir -p /media/manga && touch /media/manga/.hs-write-test && rm /media/manga/.hs-write-test' </dev/null 2>/dev/null ||
  fail "$(t "'%s' can't write to /media/manga. Look at the storage of '%s' in: hs ct list" "$user" "$ct")"

step "Uchiyomi"
# docker-compose.yml is written again at every run; the volumes keep the data. Never `docker compose down -v`
# (it deletes the Suwayomi data). PUID/PGID make the app act as the mapped user, so it may rename and delete
# files in the library. The app's own backups go to /opt/uchiyomi/backups.
low_ports
compose='mkdir -p /opt/uchiyomi/backups
  cat > /opt/uchiyomi/docker-compose.yml.new <<YML
services:
  uchiyomi:
    image: ghcr.io/angelosha/uchiyomi:latest
    container_name: uchiyomi
    restart: unless-stopped
    stop_grace_period: 40s
    ports: ["$2:3000"]
    depends_on: [uchiyomi-flaresolverr]
    environment:
      PUID: "$3"
      PGID: "$4"
      NODE_ENV: production
      PORT: "3000"
      PUBLIC_ORIGIN: "$5"
      FLARESOLVERR_URL: http://uchiyomi-flaresolverr:8191
      CUSTOM_SITES_FILE: /config/sites.json
      SUWAYOMI_URL: http://uchiyomi-suwayomi:4567
      EXTENSION_ENGINE: "1"
    volumes:
      - /media/manga:/library
      - /opt/uchiyomi/backups:/backups
      - uchiyomi_data:/data
      - uchiyomi_downloads:/library-dl
      - uchiyomi_config:/config
      - uchiyomi_cache:/cache
  uchiyomi-flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: uchiyomi-flaresolverr
    restart: unless-stopped
    shm_size: 1gb
    mem_limit: 2g
    expose: ["8191"]
    environment:
      LOG_LEVEL: warning
  uchiyomi-suwayomi:
    image: ghcr.io/suwayomi/suwayomi-server:v2.3.2243
    container_name: uchiyomi-suwayomi
    restart: unless-stopped
    mem_limit: 1536m
    expose: ["4567"]
    environment:
      TZ: "$1"
      JAVA_TOOL_OPTIONS: "-Xmx768m -XX:+UseSerialGC"
      AUTO_DOWNLOAD_CHAPTERS: "false"
      DOWNLOAD_AS_CBZ: "true"
      FLARESOLVERR_ENABLED: "true"
      FLARESOLVERR_URL: http://uchiyomi-flaresolverr:8191
    volumes:
      - uchiyomi_suwayomi:/home/suwayomi/.local/share/Tachidesk
volumes:
  uchiyomi_data:
  uchiyomi_downloads:
  uchiyomi_config:
  uchiyomi_cache:
  uchiyomi_suwayomi:
YML
  mv /opt/uchiyomi/docker-compose.yml.new /opt/uchiyomi/docker-compose.yml
  cd /opt/uchiyomi && docker compose config -q'
tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
in_ct "Writing the settings (port, user, address)" "$compose" "$tz" "$PORT" "${ids%%:*}" "${ids##*:}" "$(web)"

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Uchiyomi not started"
else
  in_ct "Downloading Uchiyomi and its helpers (about 2 GB, this takes a while)" 'cd /opt/uchiyomi && docker compose pull -q'
  in_ct "Starting Uchiyomi" 'cd /opt/uchiyomi && docker compose up -d --remove-orphans'
  wait_page Uchiyomi 'docker compose -f /opt/uchiyomi/docker-compose.yml logs --tail 50' --tries 120
fi

step "Backup"
media_backup ""
ok "$(t "'%s' is in the nightly backup (hs backup ct %s off: take it out)" "$ct" "$ct")"

unc="\\\\$(hostname)\\$share\\manga"
kv "Manga folder" "$unc"
declare_service uchiyomi Uchiyomi mdi-book-open-page-variant private-ok Apps "Manga reader"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  The first visit creates the admin account. The library is /media/manga (the folder 'manga' in the share).")
$(say "  Add the manga sources in the settings; Jellyfin does not read manga, so nothing else needs the folder.")
$(say "  No Zoraxy rule: the sign-in page is the whole app.")
$(docs_hint containers-and-apps)
DONE
