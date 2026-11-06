#!/bin/sh
# Builds a Developer ID–signed, notarized DMG: dist/VirtualCamera-<version>.dmg
#
# One-time setup (stores an app-specific password in your Keychain):
#   xcrun notarytool store-credentials vcam-notary --apple-id <apple-id> --team-id HDY4N85VD9
# Signing uses Xcode's cloud-managed Developer ID certificate (no local certificate needed).
set -e
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-vcam-notary}"
OUT="build/release"
DIST="../dist"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials named '$PROFILE'. Run once:"
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id HDY4N85VD9"
  exit 1
fi

command -v xcodegen >/dev/null && xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT" "$DIST"

echo "→ Archiving (Release, universal)"
xcodebuild archive -project VirtualCamera.xcodeproj -scheme VirtualCamera -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/VirtualCamera.xcarchive" \
  -allowProvisioningUpdates > "$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | sort -u; exit 1; }

echo "→ Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/VirtualCamera.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { grep -iE "error" "$OUT/export.log" | sort -u; exit 1; }

APP="$OUT/export/Virtual Camera.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/VirtualCamera-$VERSION.dmg"

# notarize <file> <log>: submit, wait, print Apple's log on failure.
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait | tee "$2"
  if ! grep -q "status: Accepted" "$2"; then
    ID=$(awk '/^  id:/{print $2; exit}' "$2")
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
    exit 1
  fi
}

# 1) The app itself, so its ticket is stapled inside (first launch works offline too).
echo "→ Notarizing the app (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip" "$OUT/notary-app.log"
xcrun stapler staple "$APP"

echo "→ Building $DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Virtual Camera" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

# 2) The DMG (unsigned container: the cloud Developer ID certificate only signs code,
#    which Gatekeeper accepts for disk images once the ticket is stapled).
echo "→ Notarizing the DMG"
notarize "$DMG" "$OUT/notary-dmg.log"
xcrun stapler staple "$DMG"

echo "→ Gatekeeper check"
MNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/Volumes/{print $NF}')
spctl -a -t exec -vv "$MNT/Virtual Camera.app"
xcrun stapler validate "$MNT/Virtual Camera.app"
hdiutil detach "$MNT" -quiet

shasum -a 256 "$DMG"
echo "Done: $DMG"
