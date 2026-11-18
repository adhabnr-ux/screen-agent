#!/usr/bin/env python3
"""Test pages for browser mode. Serves a page with a text box, a drag handle and a long body,
and records every event the page sees (as JSON lines) so a test can check what really happened.

  python3 test/browser_pages.py --port 8900 --log /tmp/pagelog.jsonl
"""
import argparse
import http.server
import json
import socketserver
import time

TEST_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Screen Agent test page</title>
<style>
body { margin: 0; height: 3000px; font: 16px sans-serif; }
#name { position: absolute; left: 100px; top: 100px; width: 400px; height: 40px; font-size: 18px; }
#track { position: absolute; left: 100px; top: 290px; width: 800px; height: 20px; background: #ddd; }
#handle { position: absolute; left: 100px; top: 280px; width: 40px; height: 40px; background: #36c; }
</style></head><body>
<input id="name" autocomplete="off">
<div id="track"></div><div id="handle"></div>
<script>
function log(o) { o.t = performance.now(); fetch('/log', {method: 'POST', body: JSON.stringify(o), keepalive: true}); }
var moves = 0, dragMoves = 0, drag = null;
document.addEventListener('mousemove', function (e) {
  moves++;
  if (drag) { dragMoves++; document.getElementById('handle').style.left = (drag.left + e.clientX - drag.x) + 'px'; }
});
document.addEventListener('mousedown', function (e) {
  log({event: 'down', x: e.clientX, y: e.clientY, movesBefore: moves,
       cursorShown: !!document.getElementById('__screen_agent_cursor')});
  if (e.target.id === 'handle') { drag = {x: e.clientX, y: e.clientY, left: e.target.offsetLeft}; dragMoves = 0; }
});
document.addEventListener('mouseup', function (e) {
  if (drag) { log({event: 'drag', dx: e.clientX - drag.x, dy: e.clientY - drag.y, moves: dragMoves,
                   left: document.getElementById('handle').offsetLeft}); drag = null; }
});
document.getElementById('name').addEventListener('input', function (e) { log({event: 'input', value: e.target.value}); });
var st = null;
window.addEventListener('scroll', function () { clearTimeout(st); st = setTimeout(function () { log({event: 'scroll', y: window.scrollY}); }, 150); });
log({event: 'load', page: 'test'});
</script></body></html>"""

PAGE2 = """<!doctype html><html><head><meta charset="utf-8"><title>Second page</title></head>
<body><h1>Second page</h1><script>fetch('/log', {method: 'POST', body: JSON.stringify({event: 'load', page: 'page2'})});</script>
</body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8900)
    ap.add_argument("--log", default="pagelog.jsonl")
    a = ap.parse_args()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def address_string(self):
            return self.client_address[0]

        def _send(self, code, body, ctype="text/html; charset=utf-8"):
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path.startswith("/test.html"):
                return self._send(200, TEST_PAGE)
            if self.path.startswith("/page2.html"):
                return self._send(200, PAGE2)
            self._send(404, "not found", "text/plain")

        def do_POST(self):
            n = int(self.headers.get("content-length", 0))
            raw = self.rfile.read(n).decode("utf-8", "replace")
            try:
                rec = json.loads(raw)
            except ValueError:
                rec = {"bad": raw}
            rec["server_time"] = time.time()
            with open(a.log, "a") as f:
                f.write(json.dumps(rec) + "\n")
            self._send(200, "ok", "text/plain")

    class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

        def server_bind(self):
            socketserver.TCPServer.server_bind(self)
            self.server_name, self.server_port = self.server_address[0], self.server_address[1]

    S(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
