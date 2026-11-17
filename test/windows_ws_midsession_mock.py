#!/usr/bin/env python3
"""Tiny mock for one case test/mock_api.py can't produce: the startup check passes, but
/v1/messages rejects the built-in default workspace mid-session (403 mentioning "workspace").
Writes {"posts": [workspace header or null per POST], "models": [...]} to $MOCK_REPORT."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = {"posts": [], "models": []}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        with open(os.environ["MOCK_REPORT"], "w") as f:
            json.dump(seen, f)

    def do_GET(self):
        seen["models"].append(self.headers.get("anthropic-workspace-id"))
        self.send(200, {"data": [{"id": "claude-sonnet-5-5"}]})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        ws = self.headers.get("anthropic-workspace-id")
        seen["posts"].append(ws)
        if ws:
            return self.send(403, {"type": "error", "error": {"type": "permission_error",
                             "message": "This API key cannot be used with the requested workspace."}})
        self.send(200, {"id": "msg_1", "type": "message", "role": "assistant", "model": "m",
                        "content": [{"type": "text", "text": "Nothing to do."}], "stop_reason": "end_turn",
                        "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}})


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
