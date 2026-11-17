#!/bin/bash
# Builds the Mac menu-bar app and (re)starts it from Build/HRMenuBar.app.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/generate.sh >/dev/null
# Fail loudly on a broken build instead of reinstalling the previous one.
if ! xcodebuild -project HeartRateMenuBar.xcodeproj -scheme HRMenuBar -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath .build/mac -allowProvisioningUpdates build 2>&1 \
  | tee /tmp/pulse-mac-build.log | grep -E "error:|BUILD SUCCEEDED"; then :; fi
grep -q "BUILD SUCCEEDED" /tmp/pulse-mac-build.log || { echo "Mac build failed — see /tmp/pulse-mac-build.log or open the project in Xcode."; exit 1; }
app=.build/mac/Build/Products/Debug/HRMenuBar.app
[ -d "$app" ] || { echo "Build failed — open the project in Xcode to see why."; exit 1; }
pkill -x HRMenuBar 2>/dev/null || true
# Wait for the old copy to quit; opening too early fails with error -600.
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x HRMenuBar >/dev/null || break; sleep 0.5; done
mkdir -p Build && rm -rf Build/HRMenuBar.app && cp -R "$app" Build/
# Keep only Build/HRMenuBar.app registered with macOS. Stray build copies
# make Notifications and Login Items show the wrong name or a blank icon.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -u "$app" 2>/dev/null || true
"$lsregister" -f Build/HRMenuBar.app 2>/dev/null || true
open Build/HRMenuBar.app
echo "Pulse on Mac is running in the menu bar."
