#!/bin/bash
# Direct build only: the Now Playing bridge uses private MediaRemote API.
set -euo pipefail
SOURCE="${SRCROOT}/Helpers/NowPlaying"
OUTPUT_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$OUTPUT_DIR"
xcrun clang -dynamiclib -fobjc-arc -O2 -target arm64-apple-macosx27.0 -isysroot "$SDKROOT" \
  -framework Foundation "$SOURCE/adapter.m" -o "$OUTPUT_DIR/OmniFlowNowPlaying.dylib"
# Scripts are resources: Contents/Helpers may hold only signed code.
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "$RESOURCES"
cp "$SOURCE/nowplaying.pl" "$RESOURCES/OmniFlowNowPlaying.pl"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$OUTPUT_DIR/OmniFlowNowPlaying.dylib"
fi
