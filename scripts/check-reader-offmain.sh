#!/usr/bin/env bash
# Reader callbacks that MediaPlayer, AVFoundation or Foundation run on their own
# queues must not be closures written inline in a main-actor context: Swift 6
# makes them main-actor isolated and traps when they run off the main thread
# (how the iOS Reader crashed). Each such closure must be marked @Sendable or
# come from a nonisolated factory. `--self-test` proves the check catches the
# old shapes. Needs only bash and grep.
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERN='(addTarget *\{|MPMediaItemArtwork\([^)]*\) *\{|installTap\([^{]*\{|readabilityHandler *= *\{|terminationHandler *= *\{|completionCallbackType[^{]*\{|queue: *nil\) *\{|synthesizer\.write\([^,{]*\) *\{)'

check() {
    local found=0
    while IFS= read -r file; do
        hits="$(grep -nE "$PATTERN" "$file" | grep -v '@Sendable' || true)"
        if [ -n "$hits" ]; then
            while IFS= read -r hit; do echo "$file:$hit"; done <<< "$hits"
            found=1
        fi
    done
    return $found
}

if [ "${1:-}" = "--self-test" ]; then
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/reader-offmain.XXXXXX")"
    trap 'rm -rf "$fixture"' EXIT
    cat > "$fixture/Bad.swift" <<'SWIFT'
@MainActor final class Bad {
    func setUp(_ command: MPRemoteCommand, _ image: NSImage) {
        command.addTarget { _ in .success }
        _ = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
SWIFT
    cat > "$fixture/BadVoice.swift" <<'SWIFT'
@MainActor final class BadVoice {
    let synthesizer = AVSpeechSynthesizer()
    func speak(_ utterance: AVSpeechUtterance) { synthesizer.write(utterance) { buffer in _ = buffer } }
}
SWIFT
    if find "$fixture" -name 'BadVoice.swift' | check > /dev/null; then echo "error: self-test: inline synthesizer callback was not caught" >&2; exit 1; fi
    if find "$fixture" -name '*.swift' | check > /dev/null; then echo "error: self-test: inline handlers were not caught" >&2; exit 1; fi
    echo "Reader off-main check self-test: inline handlers caught"
    exit 0
fi

# The Mac reader, the shared engine, and the iOS app (its Reader, audio and Now Playing code).
if ! { ls OmniFlow/Sources/App/Reader*.swift; find OmniFlow/Sources/Core/Reader OmniFlow/Sources/iOS -name '*.swift'; } | LC_ALL=C sort | check; then
    echo "error: build these callbacks in a nonisolated factory or mark them @Sendable." >&2
    exit 1
fi
echo "Reader off-main callbacks: clean"
