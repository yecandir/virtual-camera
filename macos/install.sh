#!/bin/sh
# Builds the signed app and installs it to /Applications (system extensions only load from there).
set -e
cd "$(dirname "$0")"
command -v xcodegen >/dev/null && xcodegen generate --quiet
APP="build/Build/Products/Debug/Virtual Camera.app"
rm -rf "$APP"
if ! xcodebuild -project VirtualCamera.xcodeproj -scheme VirtualCamera -configuration Debug \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
     > build.log 2>&1; then
  grep -E "error:" build.log | sort -u
  echo "Build failed (full log: macos/build.log)"
  exit 1
fi
codesign --verify --deep --strict "$APP"
pkill -x "Virtual Camera" 2>/dev/null || true
rm -rf "/Applications/Virtual Camera.app"
cp -R "$APP" /Applications/
open "/Applications/Virtual Camera.app"
echo "Installed and opened Virtual Camera."
