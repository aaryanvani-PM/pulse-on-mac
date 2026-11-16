#!/bin/bash
# Generates HeartRateMenuBar.xcodeproj from project.yml using your own
# Apple team and bundle-id prefix (kept in local.env, which is not committed).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f local.env ]; then
  cat <<'MSG'
Create a file named local.env in the project folder first:

  HR_TEAM_ID=ABCDE12345          # Xcode > Settings > Accounts > your team > Team ID
  HR_BUNDLE_PREFIX=com.yourname  # anything unique to you, lowercase, no spaces

A free Apple ID works (Personal Team).
MSG
  exit 1
fi
set -a; . ./local.env; set +a
: "${HR_TEAM_ID:?HR_TEAM_ID missing in local.env}"
: "${HR_BUNDLE_PREFIX:?HR_BUNDLE_PREFIX missing in local.env}"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate
