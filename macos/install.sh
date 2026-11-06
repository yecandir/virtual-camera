#!/bin/sh
# Development install: builds, signs with the SAME Developer ID identity as releases, and
# installs to /Applications (system extensions only load from there).
#
# Same signature as the release build means macOS privacy permissions (camera, microphone,
# Screen Recording) carry over between dev and release builds instead of being reset.
#
# Developer ID system extensions must be notarized to be activated, so when the extension's
# version differs from the installed one, the app is notarized first (needs the `vcam-notary`
# keychain profile, see release.sh). App-only changes skip notarization.
set -e
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-vcam-notary}"
OUT="build/dev"
EXT_ID="com.yecandir.virtualcamera.extension"

command -v xcodegen >/dev/null && xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT"

echo "→ Building"
xcodebuild archive -project VirtualCamera.xcodeproj -scheme VirtualCamera -configuration Release \
  -destination 'platform=macOS,arch=arm64' -archivePath "$OUT/VirtualCamera.xcarchive" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration > "$OUT/build.log" 2>&1 \
  || { grep -E "error:" "$OUT/build.log" | sort -u; echo "Build failed (full log: macos/$OUT/build.log)"; exit 1; }

echo "→ Signing with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/VirtualCamera.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { grep -iE "error" "$OUT/export.log" | sort -u; exit 1; }

APP="$OUT/export/Virtual Camera.app"
codesign --verify --deep --strict "$APP"

# Extension version in this build vs the active one, e.g. "1.0.0/8".
EXT_PLIST="$APP/Contents/Library/SystemExtensions/$EXT_ID.systemextension/Contents/Info.plist"
NEW_EXT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXT_PLIST")/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT_PLIST")"
ACTIVE_EXT=$(systemextensionsctl list 2>/dev/null | awk -v id="$EXT_ID" '$0 ~ id && /activated enabled/ { for (i = 1; i <= NF; i++) if ($i ~ /^\(/) { gsub(/[()]/, "", $i); print $i } }' | head -1)

if [ "$NEW_EXT" != "$ACTIVE_EXT" ]; then
  echo "→ Extension changed ($ACTIVE_EXT → $NEW_EXT): notarizing so macOS will activate it"
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarization credentials named '$PROFILE' (see release.sh)."
    exit 1
  fi
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$PROFILE" --wait > "$OUT/notary.log" 2>&1
  grep -q "status: Accepted" "$OUT/notary.log" || { cat "$OUT/notary.log"; exit 1; }
  xcrun stapler staple "$APP" >/dev/null
fi

pkill -x "Virtual Camera" 2>/dev/null || true
rm -rf "/Applications/Virtual Camera.app"
ditto "$APP" "/Applications/Virtual Camera.app"
open "/Applications/Virtual Camera.app"
echo "Installed and opened Virtual Camera."
