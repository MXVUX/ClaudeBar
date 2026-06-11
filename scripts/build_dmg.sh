#!/bin/bash
# Builds ClaudeBar.app and packages it into dist/ClaudeBar.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/ClaudeBar.app"
VERSION="${1:-1.0.0}"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/apple/Products/Release/ClaudeBar" "$APP/Contents/MacOS/ClaudeBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeBar</string>
    <key>CFBundleIdentifier</key><string>com.minhvu.claudebar</string>
    <key>CFBundleName</key><string>ClaudeBar</string>
    <key>CFBundleDisplayName</key><string>ClaudeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Minh Vu</string>
</dict>
</plist>
PLIST

echo "==> Generating icon"
swift "$ROOT/scripts/make_icon.swift" "$DIST"
iconutil -c icns "$DIST/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$DIST/AppIcon.iconset"

echo "==> Codesigning (ad-hoc)"
codesign --force --deep -s - "$APP"

echo "==> Creating DMG"
STAGING="$DIST/dmg-staging"
rm -rf "$STAGING" "$DIST/ClaudeBar.dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "ClaudeBar" -srcfolder "$STAGING" -ov -format UDZO "$DIST/ClaudeBar.dmg" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DIST/ClaudeBar.dmg"
