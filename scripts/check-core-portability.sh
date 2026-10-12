#!/usr/bin/env bash
# OmniFlow/Sources/Core is compiled into the macOS and iOS targets. Fail when a
# Core file imports a Mac-only framework or touches Mac-only process, desktop,
# pasteboard, Accessibility or event-tap APIs, or loads private frameworks.
# Needs only bash and POSIX tools (no Xcode), so CI runs it first.
set -euo pipefail
cd "$(dirname "$0")/.."
CORE="${1:-OmniFlow/Sources/Core}"

# `import AppKit`, `@preconcurrency import AppKit`, `import struct AppKit.NSColor`.
IMPORTS='(^|[[:space:]])import([[:space:]]+(typealias|struct|class|enum|protocol|let|var|func))?[[:space:]]+(AppKit|ApplicationServices|Carbon|IOKit|Cocoa|ScreenCaptureKit|SiriTTSService)([[:space:].]|$)'
# Calls and AppKit types (SwiftUI re-exports AppKit on macOS, so these can
# appear without an AppKit import). The leading class keeps `sampleProcess(` from matching `Process(`.
SYMBOLS='(^|[^[:alnum:]_.])(Process\(|NSWorkspace|NSApplication|NSApp\.|NSPasteboard|NSColor|NSImage|NSView|NSScreen|NSWindow|NSFont|NSEvent|AXUIElement|CGEvent|dlopen\(|dlsym\()'
PRIVATE='/System/Library/PrivateFrameworks|PrivateFrameworks/'

found=0
while IFS= read -r file; do
    # Ignore whole-line comments so documentation may name Mac APIs.
    hits="$(awk '{ line = $0; sub(/^[[:space:]]+/, "", line); if (line !~ /^\/\//) printf "%d:%s\n", NR, $0 }' "$file" \
        | grep -E -e "$IMPORTS" -e "$SYMBOLS" -e "$PRIVATE" || true)"
    if [ -n "$hits" ]; then
        while IFS= read -r hit; do echo "$file:$hit"; done <<< "$hits"
        found=1
    fi
done < <(find "$CORE" -type f -name '*.swift' | LC_ALL=C sort)

if [ "$found" -ne 0 ]; then
    echo "error: $CORE must stay platform-agnostic; move Mac-only code to Sources/App." >&2
    exit 1
fi
echo "Core portability: $(find "$CORE" -type f -name '*.swift' | wc -l | tr -d ' ') files clean"
