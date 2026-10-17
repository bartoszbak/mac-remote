#!/bin/zsh
# Builds a Developer ID signed Release build of the Mac app and packages it as a DMG.
#
# Usage:
#   scripts/make-dmg.sh                      # build, sign, package
#   NOTARY_PROFILE=<name> scripts/make-dmg.sh # also notarize + staple (profile from `xcrun notarytool store-credentials`)
#
# Env overrides: TEAM_ID, SIGN_IDENTITY, OUT_DIR, APP_PATH (skip the build and package an existing .app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${TEAM_ID:-TJ3ALYQV5G}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Bartosz Dariusz Bak (${TEAM_ID})}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
BUILD_DIR="${BUILD_DIR:-$(mktemp -d /tmp/macremote-dmg.XXXXXX)}"
VOLUME_NAME="MacRemote"

mkdir -p "$OUT_DIR"

if [[ -z "${APP_PATH:-}" ]]; then
  echo "▸ Building Release (signed: $SIGN_IDENTITY)"
  [[ -d "$ROOT/MacRemote.xcworkspace" ]] || (cd "$ROOT" && tuist generate --no-open >/dev/null)
  xcodebuild -workspace "$ROOT/MacRemote.xcworkspace" -scheme MacRemoteServer -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR/dd" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" build 2>&1 | grep -E "error:|warning: .*\.swift|\*\* BUILD" || true
  [[ "${pipestatus[1]}" -eq 0 ]] || { echo "xcodebuild failed"; exit 1; }
  APP_PATH="$BUILD_DIR/dd/Build/Products/Release/MacRemoteServer.app"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
DMG="$OUT_DIR/MacRemote-${VERSION}.dmg"

echo "▸ Verifying app signature"
codesign --verify --deep --strict "$APP_PATH"

echo "▸ Staging"
STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/MacRemote Server.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo "▸ Signing DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ Stapling"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "▸ Not notarized. Set NOTARY_PROFILE to notarize; unnotarized DMGs need right-click → Open on other Macs."
fi

echo "✓ $DMG (version $VERSION build $BUILD)"
