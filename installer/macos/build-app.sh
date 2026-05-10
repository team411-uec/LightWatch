#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:-0.0.0}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="LightWatch"
DERIVED_DATA_PATH="$ROOT_DIR/build/macos"
BUILT_APP_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lightwatch-dmg.XXXXXX")"
DMG_PATH="$ROOT_DIR/dist/LightWatch-macOS-$VERSION.dmg"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT

rm -rf "$DERIVED_DATA_PATH" "$DIST_DIR" "$DMG_PATH"
mkdir -p "$DIST_DIR"

xcodebuild \
  -project "$ROOT_DIR/LightWatch.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build

if [[ ! -d "$BUILT_APP_DIR" ]]; then
  echo "$APP_NAME.app was not found at $BUILT_APP_DIR." >&2
  exit 1
fi

cp -R "$BUILT_APP_DIR" "$APP_DIR"

if [[ -n "${MACOS_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$MACOS_CODESIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"
echo "$DMG_PATH"
