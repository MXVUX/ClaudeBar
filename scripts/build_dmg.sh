#!/bin/bash
# Builds ClaudePulse.app and packages it into dist/ClaudePulse.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/ClaudePulse.app"
# No default: an unversioned build looks older than every release and the
# updater happily "upgrades" it back to the latest published version.
if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version>  (e.g. 2.4.0 or 2.4.0-dev)" >&2
    exit 1
fi
VERSION="$1"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Executable keeps the original target name; only the bundle was renamed.
cp "$ROOT/.build/apple/Products/Release/ClaudePulse" "$APP/Contents/MacOS/ClaudePulse"

# CFBundleIdentifier stays com.minhvu.claudebar on purpose: changing it would
# reset every user's UserDefaults and login item.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudePulse</string>
    <key>CFBundleIdentifier</key><string>com.minhvu.claudebar</string>
    <key>CFBundleName</key><string>ClaudePulse</string>
    <key>CFBundleDisplayName</key><string>ClaudePulse</string>
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

# A stable signing identity keeps the app's designated requirement constant
# across versions. The identity keeps its historical name.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClaudeBar Signing"; then
    echo "==> Codesigning (ClaudeBar Signing)"
    codesign --force --deep -s "ClaudeBar Signing" "$APP"
else
    echo "==> Codesigning (ad-hoc — Keychain prompt will repeat after updates)"
    codesign --force --deep -s - "$APP"
fi

echo "==> Creating DMG"
STAGING="$DIST/dmg-staging"
rm -rf "$STAGING" "$DIST/ClaudePulse.dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# Hidden duplicate under the legacy name so pre-rename updaters (≤1.7.x,
# which ditto "$mount/ClaudeBar.app") can still consume this DMG; the app
# then relocates itself to ClaudePulse.app on first launch.
ditto "$APP" "$STAGING/ClaudeBar.app"
chflags hidden "$STAGING/ClaudeBar.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "ClaudePulse" -srcfolder "$STAGING" -ov -format UDZO "$DIST/ClaudePulse.dmg" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DIST/ClaudePulse.dmg"
