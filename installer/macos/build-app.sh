#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:-0.0.0}"
APP_NAME="LightWatch"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lightwatch-dmg.XXXXXX")"
DMG_PATH="$ROOT_DIR/dist/LightWatch-macOS-$VERSION.dmg"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT

rm -rf "$DIST_DIR" "$DMG_PATH"
mkdir -p "$DIST_DIR"

python3 -m pip install -e "$ROOT_DIR"
python3 -m pip install pyinstaller
python3 -m PyInstaller \
  --name "$APP_NAME" \
  --windowed \
  --osx-bundle-identifier "dev.akaaku.LightWatch" \
  --distpath "$DIST_DIR" \
  --workpath "$ROOT_DIR/build/macos" \
  --specpath "$ROOT_DIR/build/macos" \
  "$ROOT_DIR/lightwatch/app.py"

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
