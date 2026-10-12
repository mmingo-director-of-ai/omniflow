#!/usr/bin/env bash
# Fails if an iOS private API appears outside an `#if OMNIFLOW_IOS_PRIVATE_APIS`
# branch, so the review-bound AppStore configuration never compiles one in.
# `--self-test` seeds violations and proves the check catches them.
set -euo pipefail
cd "$(dirname "$0")/.."

scan() {
    python3 - "$@" <<'PY'
import re, sys
TOKENS = re.compile(r"_hostBundleID|LSApplicationWorkspace")
bad = 0
for path in sys.argv[1:]:
    stack = []  # one entry per open #if: True while inside the flag's own branch
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        s = line.strip()
        if s.startswith("#if"):
            stack.append(re.fullmatch(r"#if\s+OMNIFLOW_IOS_PRIVATE_APIS", s) is not None)
        elif s.startswith(("#elseif", "#else")) and stack:
            stack[-1] = False
        elif s.startswith("#endif") and stack:
            stack.pop()
        elif not s.startswith("//") and TOKENS.search(s) and not any(stack):
            print(f"{path}:{n}: private API outside #if OMNIFLOW_IOS_PRIVATE_APIS: {s}")
            bad = 1
sys.exit(bad)
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
    dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
    printf 'let k = "_hostBundleID"\n' > "$dir/bare.swift"
    printf '#if OMNIFLOW_IOS_PRIVATE_APIS\nlet a = 1\n#else\nlet c = NSClassFromString("LSApplicationWorkspace")\n#endif\n' > "$dir/else.swift"
    printf '#if DEBUG\nlet k = "_hostBundleID"\n#endif\n' > "$dir/other-flag.swift"
    printf '#if OMNIFLOW_IOS_PRIVATE_APIS\n#if DEBUG\nlet k = "_hostBundleID"\n#endif\n#endif\n// LSApplicationWorkspace in a comment is fine\n' > "$dir/ok.swift"
    for f in bare else other-flag; do
        if scan "$dir/$f.swift" >/dev/null; then echo "self-test: $f NOT caught"; exit 1; fi
        echo "self-test: $f caught"
    done
    scan "$dir/ok.swift" || { echo "self-test: false positive"; exit 1; }
    echo "self-test: guarded use passes"
    exit 0
fi

files=()
while IFS= read -r f; do files+=("$f"); done < <(find OmniFlow/Sources/Core OmniFlow/Sources/iOS OmniFlow/Sources/iOSShared OmniFlow/Sources/iOSWidgetShared OmniFlow/Keyboard OmniFlow/WidgetsiOS -name '*.swift' 2>/dev/null)
scan "${files[@]}"
echo "iOS private APIs: all behind OMNIFLOW_IOS_PRIVATE_APIS (${#files[@]} files)"
