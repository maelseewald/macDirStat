#!/bin/bash
# Builds MacDirStat.app into this folder.  Usage:  ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="MacDirStat.app"
echo "==> Compiling (release)…"
swift build -c release

echo "==> Creating app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MacDirStat" "$APP/Contents/MacOS/MacDirStat"

if [ ! -f .build/AppIcon.icns ]; then
  echo "==> Drawing app icon…"
  rm -rf .build/AppIcon.iconset
  swift Tools/make_icon.swift .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacDirStat</string>
  <key>CFBundleDisplayName</key><string>MacDirStat</string>
  <key>CFBundleIdentifier</key><string>local.personal.macdirstat</string>
  <key>CFBundleExecutable</key><string>MacDirStat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, for this Mac only)…"
codesign --force --sign - "$APP"

echo ""
echo "Done:  $(pwd)/$APP"
echo "Start it with:  open \"$(pwd)/$APP\"   (or copy it to /Applications)"
