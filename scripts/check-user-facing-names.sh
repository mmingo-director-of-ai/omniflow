#!/usr/bin/env bash
# The product is OmniFlow (app), Omni (assistant) and the island (notch
# surface). The fork-era names NotchLee, Notchly, NotchBuddy and Coucou are
# internal identities only. Fail when one of them appears in a string literal
# of shipped Swift/Go code, or in a plist, entitlements or project.yml value,
# unless the exact token is an internal identifier allowlisted below.
# Comments and tests are not checked: tests deliberately assert that the
# retired wake aliases are rejected. Needs only bash and python3 (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import pathlib, re, sys

FORBIDDEN = re.compile(r"notch[ _-]?lee|notch[ _-]?buddy|notchly|coucou", re.I)

# (path regex, token regex, reason). A token is removed from a literal line
# before FORBIDDEN is applied, so an entry never hides other text on the line.
# Every identity below is Part 2 work (renamed with the Developer ID change).
ALLOW = [
    (r".", r"com\.mengohlabs\.NotchLee[\w.-]*",
     "Bundle IDs, Logger/OSSignposter subsystems, queue labels and the vault Keychain service"),
    (r".", r"Helpers/NotchLee(Atlas|Speech)\b|^NotchLee(Atlas|Speech)$|\bNotchLee(Atlas|Speech)-",
     "Bundled helper executable names, checked by path at launch"),
    (r".", r"NotchLee/LocalData",
     "Application Support storage folder holding existing user data"),
    (r".", r"(Support|Logs)/NotchBuddy\b|^NotchBuddy/Cursor/|Logs/NotchBuddy$",
     "Fixed hook-relay socket, log and cursor-recovery folder; installed hooks point here"),
    (r"Sources/App/(HookServer|IslandViewContent)\.swift$", r"^NotchBuddy$",
     "Path component of the support folder, and detection of hooks installed under it"),
    (r".", r"\bcoucou_agent\b",
     "Hook payload field name kept for compatibility with installed relays"),
    (r"Sources/App/(HookServer|SettingsView)\.swift$", r"(~/\.claude/)?coucou/nb-hook|^coucou$",
     "Installed relay folder ~/.claude/coucou and the Antigravity hooks key; real paths shown verbatim"),
    (r"Sources/App/HookServer\.swift$", r"^\s*#.*\bCoucou\b",
     "Comments inside the installed relay scripts; kept byte-identical so trusted hooks keep running"),
    (r"Sources/App/(HookServer|SettingsView)\.swift$", r"^Coucou(Noop)?$",
     "NSError domains thrown by HookServer and matched by SettingsView"),
    (r"Sources/App/HookServer\.swift$", r"^coucouHooksInstalled$",
     "UserDefaults key"),
    (r"Sources/App/(AppState|SettingsView)\.swift$", r"^omniflow\.notchlyEnabled$",
     "UserDefaults key for the island toggle"),
    (r"Sources/App/[\w/]+\.swift$", r"^notchBuddy\.\w+$",
     "NotificationCenter names, internal to the process"),
    (r"\.swift$", r"^(ai\.)?notchlee\.[\w.-]+$",
     "DispatchQueue labels and the local OTLP instrumentation scope"),
    (r"\.(swift|go)$", r"^notchlee-[\w-]*$",
     "Temporary-directory prefixes for Atlas payloads"),
    (r"Sources/Core/LocalTelemetry\.swift$", r"^notchlee$",
     "OTLP service.name in local telemetry files; changing it splits existing series"),
    (r"Sources/(App|Core)/MCPOAuth\.swift$", r"^NotchLee MCP OAuth$",
     "Keychain service; existing MCP sign-ins are looked up by it"),
    (r"Sources/(App|Core)/MCPOAuth\.swift$", r"^NotchLee MCP sign-in$",
     "Keychain item label; visible in Keychain Access, renamed with the service in Part 2"),
    (r"Sources/(App|Core)/MCPOAuth\.swift$|Helpers/Atlas/mcp_http\.go$", r"^NotchLee/",
     "HTTP User-Agent product token sent to MCP and OAuth servers"),
    (r"Helpers/Atlas/mcp\.go$", r"^NotchLee$",
     "MCP clientInfo.name protocol identity"),
]
ALLOW = [(re.compile(p), re.compile(t), why) for p, t, why in ALLOW]


def swift_go_literals(src, go):
    """Yield (line, text) for every string literal, including nested ones in
    Swift interpolations. Handles //, nested /* */, \"...\", \"\"\"...\"\"\",
    #-delimited raw strings, Go `raw` strings and Go rune literals."""
    i, n, line = 0, len(src), 1
    out = []

    def code(stop_on_paren):
        nonlocal i, line
        depth = 0
        while i < n:
            c = src[i]
            if c == "\n":
                line += 1; i += 1
            elif src.startswith("//", i):
                while i < n and src[i] != "\n": i += 1
            elif src.startswith("/*", i):
                nest, i = 1, i + 2
                while i < n and nest:
                    if src.startswith("/*", i) and not go: nest += 1; i += 2
                    elif src.startswith("*/", i): nest -= 1; i += 2
                    else:
                        if src[i] == "\n": line += 1
                        i += 1
            elif go and c == "`":
                start, i = line, i + 1
                j = src.index("`", i)
                out.append((start, src[i:j])); line += src.count("\n", i, j); i = j + 1
            elif go and c == "'":
                i += 1
                while i < n and src[i] != "'":
                    i += 2 if src[i] == "\\" else 1
                i += 1
            elif c == '"' or (c == "#" and not go and re.match(r'#+"', src[i:])):
                string()
            elif stop_on_paren and c == "(":
                depth += 1; i += 1
            elif stop_on_paren and c == ")":
                if depth == 0:
                    i += 1; return
                depth -= 1; i += 1
            else:
                i += 1

    def string():
        nonlocal i, line
        hashes = 0
        while src[i] == "#": hashes += 1; i += 1
        multi = not go and src.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        start, buf = line, []
        while i < n:
            if src.startswith(close, i):
                i += len(close); break
            if src.startswith(escape, i):
                i += len(escape)
                if not go and i < n and src[i] == "(":
                    out.append((start, "".join(buf))); buf = []
                    i += 1; code(True); start = line
                    continue
                if i < n:
                    if src[i] == "\n": line += 1
                    buf.append(src[i]); i += 1
                continue
            if src[i] == "\n":
                line += 1
                if not multi: break
            buf.append(src[i]); i += 1
        out.append((start, "".join(buf)))

    code(False)
    for start, text in out:
        for k, part in enumerate(text.split("\n")):
            yield start + k, part


def plist_values(src):
    for m in re.finditer(r"<(string|key)>([^<]*)</\1>", src):
        yield src.count("\n", 0, m.start()) + 1, m.group(2)


def yaml_values(src):
    for k, raw in enumerate(src.splitlines(), 1):
        text = raw.split(" #", 1)[0]
        if not text.lstrip().startswith("#"):
            yield k, text


def files():
    root = pathlib.Path("OmniFlow")
    for p in sorted(root.rglob("*")):
        if "OmniFlow.xcodeproj" in p.parts or not p.is_file():
            continue
        if p.suffix in (".swift", ".go") and p.parts[1] in ("Sources", "Helpers"):
            yield p
        elif p.suffix in (".plist", ".entitlements") or p.name == "project.yml":
            yield p


failures = 0
checked = 0
for path in files():
    checked += 1
    rel = path.as_posix()
    src = path.read_text(errors="replace")
    if path.suffix in (".swift", ".go"):
        values = swift_go_literals(src, path.suffix == ".go")
    elif path.name == "project.yml":
        values = yaml_values(src)
    else:
        values = plist_values(src)
    rules = [t for p, t, _ in ALLOW if p.search(rel)]
    for lineno, text in values:
        if not FORBIDDEN.search(text):
            continue
        rest = text
        for token in rules:
            rest = token.sub("\x00", rest)
        if FORBIDDEN.search(rest):
            print(f"{rel}:{lineno}: {text.strip()[:160]}")
            failures += 1

if failures:
    print(f"error: {failures} user-facing fork-era name(s). Say OmniFlow, Omni or island, "
          "or allowlist an internal identifier in scripts/check-user-facing-names.sh with a reason.",
          file=sys.stderr)
    sys.exit(1)
print(f"User-facing names: {checked} files clean")
PY
