#!/bin/bash
# Renders docs/promo.mp4 (and a short docs/promo-preview.gif) with Remotion
# from frames recorded by the app's demo mode. Needs NotchApp installed
# (scripts/install.sh), Node.js and ffmpeg. The running app is closed for the
# recording (the demo uses made-up data) and relaunched afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/NotchApp.app"
OUT="$(mktemp -d)"
command -v node >/dev/null || { echo "error: Node.js not found" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

pkill -x NotchApp 2>/dev/null || true
sleep 1
NOTCHAPP_DEMO="$OUT" "$APP/Contents/MacOS/NotchApp" >/dev/null 2>&1 || true
open "$APP"
[ -f "$OUT/panel/00000.png" ] || { echo "error: no frames were recorded" >&2; exit 1; }

rm -rf "$ROOT/promo/public/panel"
mkdir -p "$ROOT/promo/public"
mv "$OUT/panel" "$ROOT/promo/public/panel"
rm -rf "$OUT"

cd "$ROOT/promo"
[ -d node_modules ] || npm install
mkdir -p "$ROOT/docs"
npm run render

# A short, lightweight taste of it for the README
ffmpeg -v error -y -ss 2.6 -t 9 -i "$ROOT/docs/promo.mp4" \
  -vf "fps=25,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=200:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 "$ROOT/docs/promo-preview.gif"
echo "wrote docs/promo.mp4 and docs/promo-preview.gif"
