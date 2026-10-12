#!/usr/bin/env bash
# Headless Reader soak: plays a book you added to Apple Books through the real
# ReaderController (audio muted) and reports gaps, drift, CPU and memory, plus
# position persistence across a restart. Counts and timings only, no text.
# Usage: scripts/test-reader-soak.sh <Books asset ID> [minutes] [voice asset key]
set -euo pipefail
cd "$(dirname "$0")/.."
READER_SOAK_ASSET="$1" READER_SOAK_MINUTES="${2:-30}" \
READER_SOAK_VOICE="${3:-$(defaults read com.mengohlabs.NotchLee omniflow.siriVoice.id 2>/dev/null || echo 'en-US:fmvoice:female:en-US-G:premium:0')}" \
READER_SOAK_HELPER="${READER_SOAK_HELPER:-/Applications/OmniFlow.app/Contents/Helpers/NotchLeeSpeech}" \
    swift test --scratch-path "${READER_SOAK_BUILD:-.build}" --filter readerSoak 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep --line-buffered -E "SOAK|✔ Test run|✘"
