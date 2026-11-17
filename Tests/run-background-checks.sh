#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/hr-background-checks.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$build_root/cache" \
  "$source_root/Watch/PassiveDiagnostics.swift" "$source_root/Shared/HRPacket.swift" "$source_root/Shared/PairingNumber.swift" "$source_root/Shared/SecureChannel.swift" "$source_root/Shared/PairingProof.swift" "$source_root/Mac/HeartRateStore.swift" "$source_root/Mac/TrendHistory.swift" "$source_root/Mac/Preferences.swift" "$source_root/Mac/HeartAlerts.swift" "$source_root/Mac/ConnectionHealth.swift" \
  "$source_root/WatchShared/ComplicationCache.swift" "$source_root/Tests/BackgroundSyncChecks.swift" \
  -o "$build_root/checks"
"$build_root/checks"
