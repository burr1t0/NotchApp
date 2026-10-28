#!/bin/bash
# Regenerates Sources/NotchApp/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
MASTER="$TMP/master.png"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
swift "$ROOT/scripts/make-icon.swift" "$MASTER"
for s in 16 32 128 256 512; do
  sips -z $s $s "$MASTER" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$MASTER" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Sources/NotchApp/AppIcon.icns"
cp "$MASTER" "$ROOT/scripts/icon-preview.png"
rm -rf "$TMP"
echo "wrote Sources/NotchApp/AppIcon.icns"
