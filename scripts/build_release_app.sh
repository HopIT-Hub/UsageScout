#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="UsageScout"
BUNDLE_ID="com.hopit.usagescout"
VERSION="${1:-0.9.0}"
BUILD_NUMBER="${2:-1}"
COPYRIGHT_TEXT="Copyright © $(date +%Y) HopIT"

DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_BINARY="$ROOT_DIR/.build/release/$APP_NAME"
ZIP_PATH="$DIST_DIR/${APP_NAME}-macOS.zip"
ICON_SOURCE="${ICON_SOURCE:-$ROOT_DIR/assets/UsageScout_Icon_Rounded.png}"
ICONSET_DIR="$DIST_DIR/${APP_NAME}.iconset"
ICON_FILE="${APP_NAME}.icns"

cd "$ROOT_DIR"

create_app_icon() {
  local src_png="$1"
  local iconset_dir="$2"
  local output_icns="$3"

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  sips -z 16 16 "$src_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$src_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$src_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$src_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$src_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$src_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$src_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$src_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$src_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  cp "$src_png" "$iconset_dir/icon_512x512@2x.png"

  iconutil -c icns "$iconset_dir" -o "$output_icns"
  rm -rf "$iconset_dir"
}

mkdir -p "$ROOT_DIR/.build/swiftpm-module-cache" "$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swiftpm-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

swift build -c release --product "$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_BINARY" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$ICON_SOURCE" ]] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
  create_app_icon "$ICON_SOURCE" "$ICONSET_DIR" "$RESOURCES_DIR/$ICON_FILE"
else
  echo "Warning: icon source or tooling missing; packaging without custom app icon."
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT_TEXT</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Built app: $APP_DIR"
echo "Built zip: $ZIP_PATH"
