#!/bin/bash
# Records the demo GIFs in docs/ from the installed app's built-in demo mode.
# Needs NotchApp installed (scripts/install.sh) and ffmpeg. The running app is
# closed for the recording (the demo uses made-up data, nothing real) and
# relaunched afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/NotchApp.app"
OUT="$(mktemp -d)"
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

pkill -x NotchApp 2>/dev/null || true
sleep 1
NOTCHAPP_DEMO="$OUT" "$APP/Contents/MacOS/NotchApp" >/dev/null 2>&1 || true
open "$APP"

mkdir -p "$ROOT/docs"
for scene in music claude tools; do
  [ -d "$OUT/$scene" ] || { echo "error: no frames for $scene" >&2; exit 1; }
  ffmpeg -v error -y -framerate 20 -i "$OUT/$scene/%04d.png" \
    -vf "format=rgb24,fps=15,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    -loop 0 "$ROOT/docs/demo-$scene.gif"
  echo "wrote docs/demo-$scene.gif"
done
