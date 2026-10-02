#!/bin/bash
# Builds Disk Recover and assembles build/DiskRecover.app (ad-hoc signed, runs locally).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

if [[ "$CONFIG" == "release" ]]; then
  swift build -c release --product DiskRecover --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/DiskRecover"
else
  swift build --product DiskRecover
  BIN=".build/debug/DiskRecover"
fi

APP="build/DiskRecover.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskRecover"

if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Disk Recover</string>
  <key>CFBundleDisplayName</key><string>Disk Recover</string>
  <key>CFBundleIdentifier</key><string>com.example.DiskRecover</string>
  <key>CFBundleExecutable</key><string>DiskRecover</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
