#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BRAND_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-brand.XXXXXX")"
trap 'rm -rf "$BRAND_BUILD_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
    OmniFlow/Sources/Core/IslandScreenGeometry.swift \
    OmniFlow/Sources/Core/IslandTypes.swift \
    OmniFlow/Sources/Core/RedPanda.swift \
    OmniFlow/Sources/App/AgentPointer.swift \
    scripts/RenderNotchLeeBrand.swift -o "$BRAND_BUILD_DIR/render"
"$BRAND_BUILD_DIR/render" OmniFlow/Assets.xcassets
