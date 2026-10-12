#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-keyboard-bridge.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# The LAN address, when there is one, must be refused: the listener is loopback-only.
{ ipconfig getifaddr en0 || ipconfig getifaddr en1 || true; } > /tmp/lanip 2>/dev/null
swiftc -swift-version 5 -parse-as-library OmniFlow/Sources/iOSShared/KeyboardBridge.swift OmniFlow/Sources/iOS/KeyboardServer.swift \
    tests/KeyboardBridgeChecks.swift -o "$TEST_DIR/keyboard-bridge"
OUTPUT="$("$TEST_DIR/keyboard-bridge")"
echo "$OUTPUT"
expect() { grep -q -- "$1" <<<"$OUTPUT" || { echo "FAIL: expected '$1'"; exit 1; }; }
expect "pairing source policy: ok"
expect "host pairing: ok"
expect "ok state       HTTP/1.1 200"
expect "consume bad id HTTP/1.1 400"
expect "body           HTTP/1.1 400"
expect "http/1.0       HTTP/1.1 400"
expect "dup token hdr  HTTP/1.1 400"
expect "oversized      HTTP/1.1 400"
expect "unknown        HTTP/1.1 404"
expect "wrong method   HTTP/1.1 405"
expect "bad token 1    HTTP/1.1 403"
expect "locked out: true listening: false"
expect "after lockout  CONNECT-REFUSED"
if [[ -s /tmp/lanip ]]; then expect "CONNECT-REFUSED"; grep -q "via LAN .* HTTP" <<<"$OUTPUT" && { echo "FAIL: reachable over LAN"; exit 1; }; fi
grep -Eq "burst 90 +429s: [1-9]" <<<"$OUTPUT" || { echo "FAIL: no rate limiting"; exit 1; }
echo "Keyboard bridge checks passed."
