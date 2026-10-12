#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
QUICK_CONTROLS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-quick-controls.XXXXXX")"
trap 'rm -rf "$QUICK_CONTROLS_TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    OmniFlow/Sources/App/OmniFlowQuickControlsGeometry.swift \
    tests/OmniFlowQuickControlsGeometryChecks.swift \
    -o "$QUICK_CONTROLS_TEST_DIR/geometry-checks"
"$QUICK_CONTROLS_TEST_DIR/geometry-checks"
