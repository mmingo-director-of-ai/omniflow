#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LOCAL_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-local-tests.XXXXXX")"
trap 'rm -rf "$LOCAL_TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(rg --files OmniFlow/Sources/App OmniFlow/Sources/Core OmniFlow/Shared -g '*.swift' | rg -v '/OmniFlowMain.swift$')
swiftc -D OMNIFLOW_STANDALONE_CHECKS -swift-version 6 -parse-as-library "${SOURCES[@]}" tests/LocalAssistantTests.swift -o "$LOCAL_TEST_DIR/local-tests"
"$LOCAL_TEST_DIR/local-tests"
