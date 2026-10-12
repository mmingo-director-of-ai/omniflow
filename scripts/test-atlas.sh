#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ATLAS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-atlas-tests.XXXXXX")"
trap 'rm -rf "$ATLAS_TEST_DIR"' EXIT
python3 scripts/build-atlas-helper.py --test --output "$ATLAS_TEST_DIR/NotchLeeAtlas"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(rg --files OmniFlow/Sources/App OmniFlow/Sources/Core OmniFlow/Shared -g '*.swift' | rg -v '/OmniFlowMain.swift$')
swiftc -D OMNIFLOW_STANDALONE_CHECKS -swift-version 6 -whole-module-optimization -Onone -parse-as-library "${SOURCES[@]}" tests/AtlasIntegrationTests.swift tests/AtlasTaskMemoryChecks.swift tests/AssistantMemoryChecks.swift tests/AtlasAnswerContextChecks.swift tests/AssistantConversationChecks.swift tests/AtlasRetrievalChecks.swift tests/AtlasMCPSelectionChecks.swift tests/AtlasMCPGenerationSchemaChecks.swift tests/AtlasMCPInitialRoutingChecks.swift tests/AtlasMCPOperationRoutingChecks.swift tests/RemoteMCPIntegrationChecks.swift tests/MCPOAuthChecks.swift -o "$ATLAS_TEST_DIR/atlas-tests"
"$ATLAS_TEST_DIR/atlas-tests" "$ATLAS_TEST_DIR/NotchLeeAtlas" OmniFlow/Helpers/Atlas/atlas-sdk.lock.json "$@"
