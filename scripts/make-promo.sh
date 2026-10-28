#!/bin/bash
# Renders docs/promo.mp4 with Remotion
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

echo "wrote docs/promo.mp4"
