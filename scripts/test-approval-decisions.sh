#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-approval.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 OmniFlow/Sources/Core/ApprovalDecisionGate.swift \
    tests/ApprovalDecisionTests.swift -o "$TEST_DIR/approval-tests"
"$TEST_DIR/approval-tests"
