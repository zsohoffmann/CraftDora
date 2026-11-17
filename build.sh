#!/bin/bash
# CraftDora – builds the .app and a .dmg (Apple silicon)
# © 2026 Zsolt Hoffmann – zsolthoffmann.com. Licensed under the GNU GPL v3 (see LICENSE).
# Usage:  cd <this folder> && bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Install it with:  xcode-select --install"
  exit 1
fi

APP="CraftDora.app"
OUT="build"
rm -rf "$OUT"
mkdir -p "$OUT/$APP/Contents/MacOS" "$OUT/$APP/Contents/Resources"

echo "▸ Compiling…"
xcrun swiftc -O -parse-as-library \
  -target arm64-apple-macos12.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$OUT/$APP/Contents/MacOS/CraftDora" \
  CraftDora.swift DMCColors.swift Export.swift Progress.swift Crop.swift

echo "▸ Icon…"
if iconutil -c icns icon/AppIcon.iconset -o "$OUT/$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then :
else cp icon/AppIcon.icns "$OUT/$APP/Contents/Resources/AppIcon.icns"; fi

# Declared languages (so the standard macOS menus are localised too)
for lang in en hu; do
  mkdir -p "$OUT/$APP/Contents/Resources/$lang.lproj"
  printf '/* CraftDora */\n' > "$OUT/$APP/Contents/Resources/$lang.lproj/Localizable.strings"
done

cat > "$OUT/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CraftDora</string>
  <key>CFBundleIdentifier</key><string>com.zsolthoffmann.craftdora</string>
  <key>CFBundleName</key><string>CraftDora</string>
  <key>CFBundleDisplayName</key><string>CraftDora</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>hu</string></array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Zsolt Hoffmann · zsolthoffmann.com</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

cp LICENSE THIRD_PARTY_NOTICES.txt "$OUT/$APP/Contents/Resources/"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$OUT/$APP"

echo "▸ Creating the DMG…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$OUT/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "CraftDora" -srcfolder "$STAGE" -ov -format UDZO "$OUT/CraftDora.dmg" >/dev/null
rm -rf "$STAGE"

echo "✓ Done: $OUT/$APP  and  $OUT/CraftDora.dmg"
open "$OUT"
