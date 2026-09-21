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

# Signing the bundle (rather than leaving only the linker's implicit ad-hoc
# signature on the raw binary inside it) is worth doing regardless: it seals
# the whole .app as one unit instead of a loose binary plus unsealed
# Resources. What it does NOT do, even with a fixed --identifier, is make a
# Full Disk Access grant survive a rebuild — ad-hoc signatures carry no
# verifiable identity (anyone can claim any --identifier), so TCC ties the
# grant to the actual signing hash underneath, which changes every time the
# binary's contents do. Only a real signing identity (a paid Developer ID, or
# a free local one you create once) gives TCC something to trust across
# rebuilds. Set ROOKMARK_CODESIGN_IDENTITY to use one:
#
#   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
#     Identity Type: Self Signed Root · Certificate Type: Code Signing
#   then: ROOKMARK_CODESIGN_IDENTITY="Your Certificate Name" ./scripts/make-app.sh
#
# With no identity set, this falls back to ad-hoc — fine for a one-off run,
# but expect to re-grant Full Disk Access after every rebuild until you set
# one up.
IDENTITY="${ROOKMARK_CODESIGN_IDENTITY:--}"
echo "Signing ($([ "$IDENTITY" = "-" ] && echo "ad hoc — grants will not survive the next rebuild" || echo "$IDENTITY"))…"
codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo "Built $APP"
echo "Run it:  open $APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Ad hoc signed: if you grant Full Disk Access now, expect to re-grant it"
    echo "again after your next rebuild. Set ROOKMARK_CODESIGN_IDENTITY to a local"
    echo "code-signing certificate (see comments in this script) to avoid that."
fi
echo
echo "To distribute, sign and notarize:"
echo "  codesign --deep --force --options runtime --sign \"Developer ID Application: ...\" $APP"
echo "  ditto -c -k --keepParent $APP build/Rookmark.zip"
echo "  xcrun notarytool submit build/Rookmark.zip --keychain-profile <profile> --wait"
echo "  xcrun stapler staple $APP"
