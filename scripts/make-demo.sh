#!/bin/bash
# Records the demo GIFs in docs/ from the installed app's built-in demo mode.
# Needs NotchApp installed (scripts/install.sh) and ffmpeg. The running app is
# closed for the recording (the demo uses made-up data, nothing real) and
# relaunched afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/NotchApp.app"
OUT="$(mktemp -d)"
FPS=50
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

pkill -x NotchApp 2>/dev/null || true
sleep 1
NOTCHAPP_DEMO="$OUT" "$APP/Contents/MacOS/NotchApp" >/dev/null 2>&1 || true
open "$APP"
[ -f "$OUT/00000.png" ] || { echo "error: no frames were recorded" >&2; exit 1; }

mkdir -p "$ROOT/docs"
# name  start  end   (seconds into the tour)
for cut in "demo 0 37" "demo-music 1.2 8" "demo-claude 7 23.5" "demo-tools 23.5 36.6"; do
  set -- $cut
  ffmpeg -v error -y -framerate $FPS -start_number "$(printf '%.0f' "$(echo "$2 * $FPS" | bc)")" \
    -i "$OUT/%05d.png" -t "$(echo "$3 - $2" | bc)" \
    -vf "format=rgb24,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=200:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 "$ROOT/docs/$1.gif"
  echo "wrote docs/$1.gif"
done
[ -n "${KEEP_FRAMES:-}" ] && echo "frames kept in $OUT" || rm -rf "$OUT"
