#!/bin/bash
# Builds the Mac menu-bar app and (re)starts it from Build/HRMenuBar.app.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/generate.sh >/dev/null
xcodebuild -project HeartRateMenuBar.xcodeproj -scheme HRMenuBar -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath .build/mac -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD" || true
app=.build/mac/Build/Products/Debug/HRMenuBar.app
[ -d "$app" ] || { echo "Build failed — open the project in Xcode to see why."; exit 1; }
pkill -x HRMenuBar 2>/dev/null || true
mkdir -p Build && rm -rf Build/HRMenuBar.app && cp -R "$app" Build/
open Build/HRMenuBar.app
echo "Heart Rate is running in the menu bar."
