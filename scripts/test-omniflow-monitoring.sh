#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OMNIFLOW_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-monitoring-tests.XXXXXX")"
trap 'rm -rf "$OMNIFLOW_TEST_DIR"' EXIT
cat > "$OMNIFLOW_TEST_DIR/main.swift" <<'SWIFT'
import Foundation

@main
struct OmniFlowMonitoringTestMain {
    @MainActor
    static func main() async throws {
        try await OmniFlowMonitoringChecks.run()
    }
}
SWIFT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(rg --files OmniFlow/Sources/App OmniFlow/Sources/Core OmniFlow/Shared -g '*.swift' | rg -v '/OmniFlowMain.swift$')
swiftc -D OMNIFLOW_STANDALONE_CHECKS -swift-version 6 -whole-module-optimization -Onone -parse-as-library \
    "${SOURCES[@]}" tests/OmniFlowMonitoringChecks.swift "$OMNIFLOW_TEST_DIR/main.swift" \
    -o "$OMNIFLOW_TEST_DIR/monitoring-tests"
"$OMNIFLOW_TEST_DIR/monitoring-tests"
