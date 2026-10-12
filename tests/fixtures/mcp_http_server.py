#!/usr/bin/env python3
"""Test-only loopback MCP endpoint; never installed or registered in NotchLee."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json


RESOURCE_TEXT = {
    "fixture://http/first": "First remote resource: café 紅熊猫.",
    "fixture://http/second": "Second remote resource: the final release is comet-73.",
}


class Fixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, status, body=None, session=False):
        encoded = b"" if body is None else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        if session:
            self.send_header("Mcp-Session-Id", "fixture-session")
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.reply(400)
            return
        if length <= 0 or length > 32768:
            self.close_connection = True
            self.reply(400)
            return
        data = self.rfile.read(length)
        if self.headers.get("Authorization") != "Bearer fixture-only":
            self.reply(401, {"error": "invalid_token"})
            return
        if self.path != "/mcp":
            self.reply(404)
            return
        try:
            request = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            self.reply(400)
            return
        method = request.get("method")
        if "id" not in request:
            self.reply(202)
            return
        result = {}
        if method == "initialize":
            result = {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": "http-test-fixture", "version": "1"},
            }
        elif method == "tools/list":
            result = {"tools": [{
                "name": "read_release_label",
                "description": "Read the fixed test release label.",
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
                "annotations": {"readOnlyHint": True},
            }]}
        elif method == "tools/call" and request.get("params", {}).get("name") == "read_release_label":
            result = {"content": [{"type": "text", "text": "The release label is aurora-42."}]}
        elif method in ("resources/list", "resources/read"):
            params = request.get("params", {})
            # Test-only audit in the caller's temporary working directory. It
            # proves rejected resource requests never reached this endpoint.
            with open("http-resource-requests.jsonl", "a", encoding="utf-8") as audit:
                audit.write(json.dumps({"method": method, "params": params}) + "\n")
            if method == "resources/list":
                cursor = params.get("cursor", "")
                if cursor not in ("", "resource-page-2"):
                    self.reply(200, {"jsonrpc": "2.0", "id": request["id"],
                                     "error": {"code": -32602, "message": "invalid fixture cursor"}})
                    return
                uri = "fixture://http/second" if cursor else "fixture://http/first"
                result = {"resources": [{"uri": uri, "name": uri.rsplit("/", 1)[1], "mimeType": "text/plain"}]}
                if not cursor:
                    result["nextCursor"] = "resource-page-2"
            else:
                uri = params.get("uri")
                if uri not in RESOURCE_TEXT:
                    self.reply(200, {"jsonrpc": "2.0", "id": request["id"],
                                     "error": {"code": -32002, "message": "resource not found"}})
                    return
                result = {"contents": [{"uri": uri, "mimeType": "text/plain", "text": RESOURCE_TEXT[uri]}]}
        else:
            self.reply(200, {"jsonrpc": "2.0", "id": request["id"],
                             "error": {"code": -32601, "message": "fixture method unavailable"}})
            return
        self.reply(200, {"jsonrpc": "2.0", "id": request["id"], "result": result}, session=method == "initialize")

    def do_DELETE(self):
        self.reply(204 if self.headers.get("Authorization") == "Bearer fixture-only" else 401)


if __name__ == "__main__":
    with HTTPServer(("127.0.0.1", 0), Fixture) as server:
        print(f"http://127.0.0.1:{server.server_port}/mcp", flush=True)
        server.serve_forever()
