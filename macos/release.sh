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

echo "→ Building $DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Virtual Camera" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "→ Notarizing (usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary.log"
if ! grep -q "status: Accepted" "$OUT/notary.log"; then
  ID=$(awk '/^  id:/{print $2; exit}' "$OUT/notary.log")
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi

echo "→ Stapling"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || true

shasum -a 256 "$DMG"
echo "Done: $DMG"
