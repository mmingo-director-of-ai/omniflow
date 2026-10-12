#!/bin/bash
set -euo pipefail
SIRI_SOURCE="${SRCROOT}/Helpers/SiriVoice"
SIRI_OUTPUT="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/NotchLeeSpeech"
mkdir -p "$(dirname "$SIRI_OUTPUT")"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx27.0 \
  -sdk "$SDKROOT" -I "$SIRI_SOURCE/PrivateInterfaces" \
  -F "$SDKROOT/System/Library/PrivateFrameworks" \
  -Xlinker -weak_framework -Xlinker SiriTTSService \
  "$SIRI_SOURCE/main.swift" -o "$SIRI_OUTPUT"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$SIRI_OUTPUT"
fi
