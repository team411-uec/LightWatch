#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:-0.0.0}"
APP_NAME="LightWatch"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_DIR="$DIST_DIR/$APP_NAME.app"
BUILD_DIR="$ROOT_DIR/build/macos"
VENV_DIR="$BUILD_DIR/venv"
TMP_ROOT="$BUILD_DIR/tmp"
DMG_PATH="$ROOT_DIR/dist/LightWatch-macOS-$VERSION.dmg"

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON="$PYTHON_BIN"
elif command -v python3.11 >/dev/null 2>&1; then
  PYTHON="python3.11"
else
  PYTHON="python3"
fi

rm -rf "$BUILD_DIR" "$DIST_DIR" "$DMG_PATH"
mkdir -p "$DIST_DIR" "$TMP_ROOT"
DMG_STAGING_DIR="$(mktemp -d "$TMP_ROOT/lightwatch-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT

"$PYTHON" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -e "$ROOT_DIR" pyinstaller
"$VENV_DIR/bin/python" -m PyInstaller \
  --name "$APP_NAME" \
  --windowed \
  --osx-bundle-identifier "dev.akaaku.LightWatch" \
  --distpath "$DIST_DIR" \
  --workpath "$BUILD_DIR/pyinstaller" \
  --specpath "$BUILD_DIR" \
  --add-data "$ROOT_DIR/lightwatch/assets/selfie_segmentation_landscape.tflite:lightwatch/assets" \
  --hidden-import "ai_edge_litert._pywrap_litert_interpreter_wrapper" \
  "$ROOT_DIR/lightwatch/app.py"

/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string Webカメラ映像の明るさ変化から部屋の使用状態の可能性を判定するために使用します。" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :NSCameraUsageDescription Webカメラ映像の明るさ変化から部屋の使用状態の可能性を判定するために使用します。" "$APP_DIR/Contents/Info.plist"

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
