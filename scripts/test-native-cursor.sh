#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CURSOR_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-cursor-tests.XXXXXX")"
trap 'rm -rf "$CURSOR_TEST_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library OmniFlow/Sources/App/AgentPointer.swift \
  tests/NativeCursorTests.swift -o "$CURSOR_TEST_DIR/cursor-tests"
"$CURSOR_TEST_DIR/cursor-tests" "$@"
