#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-voice.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 OmniFlow/Sources/Core/VoiceSessionContext.swift \
    tests/VoiceSessionTests.swift -o "$TEST_DIR/voice-tests"
"$TEST_DIR/voice-tests"
