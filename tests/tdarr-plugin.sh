#!/usr/bin/env bash
# Tdarr plugin of the tdarr recipe: builds small test films with ffmpeg and checks what the
# plugin decides and that its ffmpeg arguments really produce the tracks it promises.
# Needs node, ffmpeg and ffprobe; skips (exit 0) without them.
set -euo pipefail
cd "$(dirname "$0")"
for c in node ffmpeg ffprobe; do
  command -v "$c" >/dev/null || { echo "skip: $c not installed"; exit 0; }
done
node tdarr-plugin.js
