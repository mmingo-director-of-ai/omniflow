#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FOCUS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-focus.XXXXXX")"
trap 'rm -rf "$FOCUS_TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  OmniFlow/Sources/App/OmniFlowFocusController.swift \
  OmniFlow/Sources/App/OmniFlowFocusEngine.swift \
  OmniFlow/Sources/App/OmniFlowFocusSettings.swift \
  OmniFlow/Sources/App/OmniFlowFocusWindow.swift \
  tests/OmniFlowFocusChecks.swift -o "$FOCUS_TEST_DIR/focus-checks"
"$FOCUS_TEST_DIR/focus-checks"
