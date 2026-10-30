#!/usr/bin/env bash
# Radarr / Sonarr settings through their v3 API (run on the host by the recipes radarr and sonarr, each has this same file:
# tests/media-recipes.sh keeps the two copies equal):
#   arr-tune.sh <ip> <port> <api key> <recycle folder> <days>
# Prints key=value lines (recycle=set|same|failed, client=set|same|none|failed), never raw output. Idempotent.
# Field names: MediaManagementConfigResource.RecycleBin / RecycleBinCleanupDays (PUT /api/v3/config/mediamanagement,
# the object read first, so nothing else changes) and DownloadClientResource.RemoveCompletedDownloads
# (PUT /api/v3/downloadclient/{id}), both in the Radarr and Sonarr source (src/<App>.Api.V3).
set -uo pipefail
ip=$1 port=$2 key=$3 bin=$4 days=$5
base="http://$ip:$port/api/v3"
api() { curl -fsS -m 15 -H "X-Api-Key: $key" -H 'Content-Type: application/json' "$@"; }

cfg=$(api "$base/config/mediamanagement" 2>/dev/null) || { echo recycle=failed; echo client=failed; exit 0; }
if [ "$(jq -r '"\(.recycleBin)|\(.recycleBinCleanupDays)"' <<<"$cfg")" = "$bin|$days" ]; then echo recycle=same
else
  new=$(jq -c --arg b "$bin" --argjson d "$days" '.recycleBin = $b | .recycleBinCleanupDays = $d' <<<"$cfg")
  if api -X PUT -d "$new" "$base/config/mediamanagement" >/dev/null 2>&1; then echo recycle=set; else echo recycle=failed; fi
fi

clients=$(api "$base/downloadclient" 2>/dev/null) || { echo client=failed; exit 0; }
ids=$(jq -r '.[] | select(.implementation == "Sabnzbd") | .id' <<<"$clients")
if [ -z "$ids" ]; then echo client=none; exit 0; fi
res=same
for id in $ids; do
  c=$(jq -c --argjson i "$id" '.[] | select(.id == $i)' <<<"$clients")
  [ "$(jq -r .removeCompletedDownloads <<<"$c")" = true ] && continue
  if api -X PUT -d "$(jq -c '.removeCompletedDownloads = true' <<<"$c")" "$base/downloadclient/$id" >/dev/null 2>&1; then res=set; else res=failed; break; fi
done
echo client=$res
