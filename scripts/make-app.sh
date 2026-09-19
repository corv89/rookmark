#!/usr/bin/env bash
# Package the built executable as Rookmark.app.
#
# Two things only a real bundle can give us:
#   - the display name. A bare SwiftPM binary shows its filename in the menu bar
#     and Cmd-Tab, which is "RookmarkApp" (the target has to differ from the
#     "rookmark" CLI, since macOS filesystems are case-insensitive). Inside
#     Contents/MacOS there is no such clash, so the binary is named Rookmark.
#   - the icon, via CFBundleIconFile, rather than being set at runtime.
#
# This is also the starting point for codesigning and notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Rookmark.app"
BUNDLE_ID="${ROOKMARK_BUNDLE_ID:-com.example.rookmark}"
VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product RookmarkApp

BIN="$(swift build -c "$CONFIG" --product RookmarkApp --show-bin-path)/RookmarkApp"
[ -x "$BIN" ] || { echo "executable not found: $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Rookmark"
cp icon/Rookmark.icns "$APP/Contents/Resources/Rookmark.icns"

# SwiftPM emits resources as a sibling .bundle; it has to travel with the binary
# or Bundle.module traps at runtime.
for b in "$(dirname "$BIN")"/*_RookmarkApp.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Rookmark</string>
    <key>CFBundleDisplayName</key><string>Rookmark</string>
    <key>CFBundleExecutable</key><string>Rookmark</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>Rookmark</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPLv3 licensed</string>
</dict>
</plist>
PLIST

# Refresh the icon cache, otherwise Finder keeps showing the generic icon.
touch "$APP"

echo "Built $APP"
echo "Run it:  open $APP"
echo
echo "To distribute, sign and notarize:"
echo "  codesign --deep --force --options runtime --sign \"Developer ID Application: ...\" $APP"
echo "  ditto -c -k --keepParent $APP build/Rookmark.zip"
echo "  xcrun notarytool submit build/Rookmark.zip --keychain-profile <profile> --wait"
echo "  xcrun stapler staple $APP"
