#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CURSOR_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-context-tests.XXXXXX")"
trap 'rm -rf "$CURSOR_TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do
    snapshot="$CURSOR_TEST_DIR/$(basename "$source")"
    cp "$source" "$snapshot"
    SOURCES+=("$snapshot")
done < <(rg --files OmniFlow/Sources/App OmniFlow/Sources/Core OmniFlow/Shared -g '*.swift' | rg -v '/OmniFlowMain.swift$')
swiftc -D OMNIFLOW_STANDALONE_CHECKS -swift-version 6 -whole-module-optimization -parse-as-library "${SOURCES[@]}" tests/CursorAmbientTests.swift tests/OmniFlowInteractionLeaseChecks.swift -o "$CURSOR_TEST_DIR/context-tests"
"$CURSOR_TEST_DIR/context-tests"
