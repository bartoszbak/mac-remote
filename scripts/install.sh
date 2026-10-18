#!/bin/zsh
# Builds the Mac app signed with the Developer ID (same identity as every other build,
# so permissions persist), installs it into /Applications and relaunches it.
#
# Usage: scripts/install.sh [Debug|Release]   (default: Release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Developer/Xcode/DerivedData/MacRemote-install}"
APP_NAME="MacRemoteServer.app"
# Same name the DMG uses, so there is only ever one copy and the login item keeps working.
INSTALLED_NAME="MacRemote Server.app"

[[ -d "$ROOT/MacRemote.xcworkspace" ]] || (cd "$ROOT" && tuist generate --no-open >/dev/null)

echo "▸ Building $CONFIG"
xcodebuild -workspace "$ROOT/MacRemote.xcworkspace" -scheme MacRemoteServer -configuration "$CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" build 2>&1 \
  | grep -E "error:|warning: .*\.swift|\*\* BUILD" || true
[[ "${pipestatus[1]}" -eq 0 ]] || { echo "xcodebuild failed"; exit 1; }

APP="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME"
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep -q 'subject.OU\] = TJ3ALYQV5G' || { echo "app is not signed with the Developer ID; permissions would reset"; exit 1; }

echo "▸ Installing"
pkill -x MacRemoteServer 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME" "/Applications/$INSTALLED_NAME"
cp -R "$APP" "/Applications/$INSTALLED_NAME"
open "/Applications/$INSTALLED_NAME"
echo "✓ Installed and launched /Applications/$INSTALLED_NAME ($CONFIG)"
