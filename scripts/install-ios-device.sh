#!/bin/bash
# Builds the current checkout for a connected iPhone or iPad, installs it and
# relaunches it, stamping the build so installs can be told apart:
# CFBundleVersion = commit count, OmniFlowGitSHA = short SHA (+ "-dirty").
# Usage: scripts/install-ios-device.sh <device-udid> [team-id]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?device UDID (xcrun devicectl list devices)}"
TEAM="${2:-TK32DMT83D}"
BUILD="$(git rev-list --count HEAD)"
SHA="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- OmniFlow || echo -dirty)"
OUT="${TMPDIR:-/tmp}/omniflow-ios-device"
(cd OmniFlow && xcodegen generate -q)
xcodebuild -project OmniFlow/OmniFlow.xcodeproj -scheme OmniFlowiOS -destination "id=$DEVICE" -derivedDataPath "$OUT" \
    -allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic OMNIFLOW_BUILD="$BUILD" OMNIFLOW_GIT_SHA="$SHA" build \
    | grep -E " error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="$OUT/Build/Products/Debug-iphoneos/OmniFlow.app"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "App installed|rror"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.mengohlabs.NotchLee.ios | tail -1
echo "Installed OmniFlow build $BUILD ($SHA)"
