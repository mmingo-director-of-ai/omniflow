#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ASSISTANT_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-context.XXXXXX")"
trap 'rm -rf "$ASSISTANT_TEST_DIR"' EXIT
swiftc -swift-version 6 OmniFlow/Sources/App/CursorContext.swift \
    OmniFlow/Sources/Core/SessionFailure.swift tests/AssistantContextTests.swift \
    -o "$ASSISTANT_TEST_DIR/context-tests"
"$ASSISTANT_TEST_DIR/context-tests"
