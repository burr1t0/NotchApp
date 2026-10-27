#!/bin/bash
# Build NotchApp and install it into /Applications, replacing the running copy.
#
#   scripts/install.sh              Release build, install, relaunch
#   scripts/install.sh --debug      Debug build instead of Release
#   scripts/install.sh --no-launch  install but don't open the app afterwards
#
# Requires: Xcode (selected with xcode-select), xcodegen (brew install xcodegen),
# and an Apple ID signed in to Xcode — the stable "Apple Development"
# signature is what keeps macOS permissions (e.g. system audio capture)
# attached to the app across rebuilds.

set -euo pipefail

APP_NAME="NotchApp"
CONFIG="Release"
LAUNCH=1

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="Debug" ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DEST="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

die() { echo "error: $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found — install it with: brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found — install Xcode"
case "$(xcode-select -p 2>/dev/null)" in
  *Xcode*.app*) ;;
  *) die "xcode-select points at the Command Line Tools, not Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
esac

cd "$ROOT"

# --- build -------------------------------------------------------------------
echo "==> Generating Xcode project from project.yml"
xcodegen generate --quiet

echo "==> Building $APP_NAME ($CONFIG)"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -allowProvisioningUpdates \
  -quiet \
  build

BUILT="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$BUILT" ] || die "build finished but $BUILT is missing"

# --- install -----------------------------------------------------------------
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Stopping running $APP_NAME"
  pkill -x "$APP_NAME" || true
  for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

echo "==> Installing to $DEST"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# xcodebuild registers its own product with LaunchServices, which makes
# Spotlight list a second "$APP_NAME" next to the installed one.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true

echo "==> Verifying signature"
codesign --verify --deep --strict "$DEST" || die "signature verification failed for $DEST"
codesign -dvv "$DEST" 2>&1 | grep -E "^(Authority=Apple Development|TeamIdentifier)" || true

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> Launching"
  open "$DEST"
fi

echo "Done: $DEST ($CONFIG)"
