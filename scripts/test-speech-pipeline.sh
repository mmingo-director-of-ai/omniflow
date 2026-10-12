#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SPEECH_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchlee-speech.XXXXXX")"
trap 'rm -rf "$SPEECH_TEST_DIR"' EXIT
SIRI_HELPER="${1:-/Applications/OmniFlow.app/Contents/Helpers/NotchLeeSpeech}"
python3 - "$SIRI_HELPER" "$SPEECH_TEST_DIR" <<'PYTHON'
import json, subprocess, sys
from pathlib import Path
helper, folder = sys.argv[1:]
voices = json.loads(subprocess.check_output([helper, 'voices'], timeout=12))
voices = [v for v in voices if v['name'] == 'en-US-G' and v['language'] == 'en-US']
assert voices, 'Install Siri Voice 6 before running this integration check.'
voice = next((v for v in voices if ':fmvoice:' in v['id']), voices[0])
for name, phrase in [('hey', 'Hey Omni, which agent is waiting for me?'),
                     ('name', 'Omni, which agent is waiting for me?')]:
    output = str(Path(folder) / (name + '.wav'))
    subprocess.run([helper, 'speak', voice['id'], output, '1', '1'],
                   input=phrase.encode(), check=True, timeout=40)
subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1',
                str(Path(folder) / 'name.wav'), str(Path(folder) / 'name-16k.wav')], check=True)
PYTHON
swiftc -swift-version 6 -parse-as-library \
    OmniFlow/Sources/Core/VoiceSessionContext.swift OmniFlow/Sources/App/VoiceInput.swift \
    tests/SpeechPipelineTests.swift -o "$SPEECH_TEST_DIR/speech-test"
"$SPEECH_TEST_DIR/speech-test" "$SPEECH_TEST_DIR/hey.wav"
"$SPEECH_TEST_DIR/speech-test" "$SPEECH_TEST_DIR/name-16k.wav"
