#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-widget-group.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 OmniFlow/Shared/OmniFlowWidgetSnapshot.swift \
    tests/WidgetAppGroupTests.swift -o "$TEST_DIR/widget-group-tests"
"$TEST_DIR/widget-group-tests"
