#!/usr/bin/env bash
# Reader pronunciation check: the Siri voice must say acronyms, numbers and
# links as the reader intends (>= 95%). Synthesizes with the installed Siri
# helper and transcribes on-device; no book text. Optional voice asset key.
set -euo pipefail
cd "$(dirname "$0")/.."
HELPER="${READER_HARNESS_HELPER:-/Applications/OmniFlow.app/Contents/Helpers/NotchLeeSpeech}"
VOICE="${1:-$(defaults read com.mengohlabs.NotchLee omniflow.siriVoice.id 2>/dev/null || echo 'en-US:fmvoice:female:en-US-G:premium:0')}"
READER_HARNESS_HELPER="$HELPER" READER_HARNESS_VOICE="$VOICE" swift test --filter readerPronunciationHarness 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | tee /dev/stderr | grep -q "✔ Test run with 1 test"
