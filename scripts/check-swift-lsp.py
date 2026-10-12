#!/usr/bin/env python3
"""Query the installed SourceKit-LSP against the repository's Xcode build server.

Run xcode-build-server config/parse first. This is editor diagnostics, not a
replacement for builds, runtime tests, or native visual acceptance.
"""
import argparse
import json
import pathlib
import queue
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--prove-semantic", action="store_true")
    parser.add_argument("--output", default="/tmp/omniflow-lsp-results.json")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    if not (root / "buildServer.json").exists():
        raise SystemExit("Configure the installed xcode-build-server for this checkout first.")
    events = queue.Queue()
    stderr = open("/tmp/omniflow-sourcekit-lsp.log", "w")
    server = subprocess.Popen(["xcrun", "sourcekit-lsp", "--bypass-workspace-trust"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, cwd=root)
    request_id = 0
    pushes = {}

    def read():
        while True:
            headers = {}
            while (line := server.stdout.readline()) not in (b"\r\n", b"\n", b""):
                key, value = line.decode().split(":", 1)
                headers[key.lower()] = value.strip()
            if not line:
                return
            events.put(json.loads(server.stdout.read(int(headers["content-length"]))))

    threading.Thread(target=read, daemon=True).start()

    def send(value):
        data = json.dumps({"jsonrpc": "2.0", **value}).encode()
        server.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        server.stdin.flush()

    def request(method, params, timeout=50):
        nonlocal request_id
        request_id += 1
        current = request_id
        send({"id": current, "method": method, "params": params})
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            message = events.get(timeout=max(.1, end - time.monotonic()))
            if message.get("id") == current and "method" not in message:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"]))
                return message.get("result")
            if "id" in message and "method" in message:
                result = [None] * len(message.get("params", {}).get("items", [])) if message["method"] == "workspace/configuration" else None
                send({"id": message["id"], "result": result})
            if message.get("method") == "textDocument/publishDiagnostics":
                pushes[message["params"]["uri"]] = message["params"]["diagnostics"]
        raise TimeoutError(method)

    results = []
    semantic_probe = False
    try:
        initialized = request("initialize", {"processId": None, "rootUri": root.as_uri(),
            "workspaceFolders": [{"uri": root.as_uri(), "name": "OmniFlow"}],
            "capabilities": {"workspace": {"configuration": True},
                "textDocument": {"diagnostic": {"relatedDocumentSupport": True},
                    "publishDiagnostics": {"relatedInformation": True}}},
            "initializationOptions": {"backgroundIndexing": False}})
        send({"method": "initialized", "params": {}})
        for name in args.files:
            path = (root / name).resolve()
            send({"method": "textDocument/didOpen", "params": {"textDocument": {
                "uri": path.as_uri(), "languageId": "swift", "version": 1, "text": path.read_text()}}})
            symbols = request("textDocument/documentSymbol", {"textDocument": {"uri": path.as_uri()}})
            if args.prove_semantic and not semantic_probe:
                probe = path.read_text() + "\nprivate func omniflowLSPProbe() { missingOmniFlowSemanticProbe() }\n"
                send({"method": "textDocument/didChange", "params": {"textDocument": {"uri": path.as_uri(), "version": 2}, "contentChanges": [{"text": probe}]}})
                found = request("textDocument/diagnostic", {"textDocument": {"uri": path.as_uri()}})
                semantic_probe = any("missingOmniFlowSemanticProbe" in d.get("message", "") and d.get("severity") == 1 for d in found.get("items", []))
                if not semantic_probe:
                    raise RuntimeError("SourceKit did not diagnose the unsaved semantic negative control")
                send({"method": "textDocument/didChange", "params": {"textDocument": {"uri": path.as_uri(), "version": 3}, "contentChanges": [{"text": path.read_text()}]}})

            diagnostics = request("textDocument/diagnostic", {"textDocument": {"uri": path.as_uri()}})
            results.append({"file": str(path.relative_to(root)), "symbolCount": len(symbols or []),
                "diagnostics": diagnostics.get("items", []), "kind": diagnostics.get("kind")})
            send({"method": "textDocument/didClose", "params": {"textDocument": {"uri": path.as_uri()}}})
        report = {"server": initialized.get("serverInfo"), "buildServer": "installed xcode-build-server",
            "semanticNegativeControlPassed": semantic_probe, "results": results, "errors": sum(d.get("severity") == 1 for r in results for d in r["diagnostics"])}
        pathlib.Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"server": report["server"], "semanticNegativeControlPassed": semantic_probe, "files": len(results), "errors": report["errors"], "report": args.output}))
        request("shutdown", None, timeout=10)
        send({"method": "exit", "params": {}})
        return 1 if report["errors"] else 0
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        stderr.close()


if __name__ == "__main__":
    raise SystemExit(main())
