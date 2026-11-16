#!/bin/bash
# Builds the Watch app and installs it on your paired Apple Watch. With a free
# Apple ID the app stops launching after 7 days: run this again to renew it.
# Pairing and settings are kept across reinstalls.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/generate.sh >/dev/null
watch="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/Apple Watch/ && /paired|connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')}"
[ -n "$watch" ] || { echo "No Apple Watch found. Unlock it, keep it near this Mac on the same Wi-Fi, and enable Developer Mode."; exit 1; }
xcodebuild -project HeartRateMenuBar.xcodeproj -scheme HRWatchApp -configuration Debug \
  -destination 'generic/platform=watchOS' -derivedDataPath .build/watch -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD" || true
app=.build/watch/Build/Products/Debug-watchos/HRWatchApp.app
[ -d "$app" ] || { echo "Build failed — open the project in Xcode, select your team, and try again."; exit 1; }
xcrun devicectl device install app --device "$watch" "$app" | grep -E "bundleID|ERROR" || true
echo "Installed. Open Heart Rate Mac on the Watch once, then add its complication to your watch face."
