#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WAKE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-wake-tests.XXXXXX")"
trap 'rm -rf "$WAKE_TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do
    snapshot="$WAKE_TEST_DIR/$(basename "$source")"
    cp "$source" "$snapshot"
    SOURCES+=("$snapshot")
done < <(rg --files OmniFlow/Sources/App OmniFlow/Sources/Core OmniFlow/Shared -g '*.swift' | rg -v '/OmniFlowMain.swift$')
swiftc -D OMNIFLOW_STANDALONE_CHECKS -swift-version 6 -whole-module-optimization -parse-as-library "${SOURCES[@]}" tests/WakeListenerTests.swift -o "$WAKE_TEST_DIR/wake-tests"
"$WAKE_TEST_DIR/wake-tests"
