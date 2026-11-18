"""Browser mode for Screen Agent.

Instead of the whole desktop, Claude drives its own Chromium window through the Chrome DevTools
Protocol (the same way the Cline extension's browser tool works). Used where the desktop itself
can't be controlled, for example VS Code on a Chromebook (Linux container) or in GitHub Codespaces.

Standard library only. The browser is found, not installed: SCREEN_AGENT_CHROME, then Chrome or
Chromium on PATH, then the Chromium the Cline extension downloads into VS Code's storage, then the
Puppeteer / Playwright caches.

agent.py imports this module and hands it the pieces it shares (glide math, Stopped, settings).
"""
import base64
import glob
import http.server
import json
import math
import os
import shutil
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

VIEW_W, VIEW_H = 1280, 800  # the page area Claude sees and clicks in, in CSS pixels
PROFILE = os.path.expanduser("~/.screen-agent/browser-profile")
LIVE_PORT = int(os.environ.get("SCREEN_AGENT_LIVE_PORT", "8890"))

# The custom tool Claude uses for what screenshots of the page can't show: the address bar and tabs.
BROWSER_TOOL = {
    "name": "browser",
    "description": (
        "Control the browser itself. Screenshots show only the web page, not the address bar or tabs, "
        "so use this to open a web address, go back or forward, reload, and open, switch or close tabs. "
        "Every call returns the list of open tabs; the current one is marked with *."),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {"type": "string",
                       "enum": ["navigate", "back", "forward", "reload", "new_tab", "switch_tab",
                                "close_tab", "list_tabs"]},
            "url": {"type": "string", "description": "For navigate and new_tab. A full address or a plain domain."},
            "tab": {"type": "integer", "description": "For switch_tab and close_tab: the tab number from the list."},
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}

BROWSER_INTRO = ("You are Screen Agent, operating a web browser (Chromium) for the person at the keyboard through "
                 "the computer tools and the browser tool. Screenshots are {sw}x{sh} pixels and show only the web "
                 "page; all coordinates you give are in that space.")
BROWSER_HINT = (" Use the browser tool to open addresses and manage tabs; browser shortcuts such as ctrl+t or "
                "ctrl+l don't work here. Inside a page, shortcuts use ctrl.")

# key name -> (DOM key, DOM code, Windows virtual key code, text it types)
NAMED = {
    "return": ("Enter", "Enter", 13, "\r"), "enter": ("Enter", "Enter", 13, "\r"),
    "tab": ("Tab", "Tab", 9, ""), "escape": ("Escape", "Escape", 27, ""), "esc": ("Escape", "Escape", 27, ""),
    "backspace": ("Backspace", "Backspace", 8, ""), "delete": ("Delete", "Delete", 46, ""),
    "del": ("Delete", "Delete", 46, ""), "space": (" ", "Space", 32, " "),
    "up": ("ArrowUp", "ArrowUp", 38, ""), "down": ("ArrowDown", "ArrowDown", 40, ""),
    "left": ("ArrowLeft", "ArrowLeft", 37, ""), "right": ("ArrowRight", "ArrowRight", 39, ""),
    "home": ("Home", "Home", 36, ""), "end": ("End", "End", 35, ""),
    "page_up": ("PageUp", "PageUp", 33, ""), "pageup": ("PageUp", "PageUp", 33, ""), "prior": ("PageUp", "PageUp", 33, ""),
    "page_down": ("PageDown", "PageDown", 34, ""), "pagedown": ("PageDown", "PageDown", 34, ""),
    "next": ("PageDown", "PageDown", 34, ""), "insert": ("Insert", "Insert", 45, ""),
    "capslock": ("CapsLock", "CapsLock", 20, ""),
}
for _i in range(1, 13):
    NAMED["f%d" % _i] = ("F%d" % _i, "F%d" % _i, 111 + _i, "")
# modifier name -> (CDP modifier bit, DOM key, DOM code, virtual key)
MODS = {
    "alt": (1, "Alt", "AltLeft", 18), "option": (1, "Alt", "AltLeft", 18), "opt": (1, "Alt", "AltLeft", 18),
    "ctrl": (2, "Control", "ControlLeft", 17), "control": (2, "Control", "ControlLeft", 17),
    "super": (4, "Meta", "MetaLeft", 91), "cmd": (4, "Meta", "MetaLeft", 91), "command": (4, "Meta", "MetaLeft", 91),
    "win": (4, "Meta", "MetaLeft", 91), "meta": (4, "Meta", "MetaLeft", 91),
    "shift": (8, "Shift", "ShiftLeft", 16),
}
PUNCT_CODES = {"-": ("Minus", 189), "=": ("Equal", 187), "[": ("BracketLeft", 219), "]": ("BracketRight", 221),
               "\\": ("Backslash", 220), ";": ("Semicolon", 186), "'": ("Quote", 222), ",": ("Comma", 188),
               ".": ("Period", 190), "/": ("Slash", 191), "`": ("Backquote", 192)}

CURSOR_JS = """(function(x, y) {
  var c = document.getElementById('__screen_agent_cursor');
  if (!c) {
    c = document.createElement('div');
    c.id = '__screen_agent_cursor';
    c.setAttribute('aria-hidden', 'true');
    c.style.cssText = 'position:fixed;left:0;top:0;width:20px;height:22px;z-index:2147483647;' +
      'pointer-events:none;will-change:transform';
    c.innerHTML = '<svg width="20" height="22" viewBox="0 0 20 22"><path d="M2 1 L2 17 L6.5 13 L9.5 20 ' +
      'L12.3 18.8 L9.3 12 L15.5 12 Z" fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>';
    (document.body || document.documentElement).appendChild(c);
  }
  c.style.transform = 'translate(' + (x - 2) + 'px,' + (y - 1) + 'px)';
})(%d, %d)"""


class BrowserError(Exception):
    pass


# --------------------------------------------------------------------------- finding and starting Chromium

def _runnable(path):
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def find_chrome():
    """Path to a Chrome/Chromium binary, or None. Nothing is downloaded."""
    env = os.environ.get("SCREEN_AGENT_CHROME", "").strip()
    if env:
        return env if _runnable(env) else None
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome"):
        p = shutil.which(name)
        if _runnable(p):
            return p
    home = os.path.expanduser("~")
    storage_roots = [
        ".config/Code/User/globalStorage", ".config/Code - OSS/User/globalStorage",
        ".config/Code - Insiders/User/globalStorage", ".config/VSCodium/User/globalStorage",
        ".config/Cursor/User/globalStorage", ".vscode-remote/data/User/globalStorage",
        ".vscode-server/data/User/globalStorage", ".vscode-server-insiders/data/User/globalStorage",
        ".cursor-server/data/User/globalStorage", ".local/share/code-server/User/globalStorage",
        ".openvscode-server/data/User/globalStorage",
    ]
    patterns = []
    for root in storage_roots:
        # the Cline extension keeps its Chromium here (puppeteer-chromium-resolver)
        base = os.path.join(home, root, "saoudrizwan.claude-dev", "puppeteer", ".chromium-browser-snapshots")
        patterns += [os.path.join(base, "*", "chrome-linux*", "chrome"),
                     os.path.join(base, "*", "*", "chrome-linux*", "chrome")]
    patterns += [os.path.join(home, ".cache/puppeteer/chrome/*/chrome-linux64/chrome"),
                 os.path.join(home, ".cache/ms-playwright/chromium-*/chrome-linux*/chrome")]
    found = []
    for pat in patterns:
        found += [p for p in glob.glob(pat) if _runnable(p)]
    if not found:
        return None
    return max(found, key=os.path.getmtime)  # newest download


def _has_display():
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def _launch(chrome, headless, no_sandbox, profile, log_path):
    args = [chrome, "--remote-debugging-port=0", "--remote-allow-origins=*", "--user-data-dir=" + profile,
            "--no-first-run", "--no-default-browser-check", "--disable-features=Translate",
            # never ask the system keychain / keyring for anything (no "unlock keyring" or "keychain" pop-ups)
            "--password-store=basic", "--use-mock-keychain",
            "--window-size=%d,%d" % (VIEW_W + 20, VIEW_H + 140), "about:blank"]
    if headless:
        args.insert(1, "--headless=new")
    if no_sandbox:
        args.insert(1, "--no-sandbox")
    port_file = os.path.join(profile, "DevToolsActivePort")
    try:
        os.remove(port_file)
    except OSError:
        pass
    log = open(log_path, "wb")
    proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            start_new_session=True)
    deadline = time.time() + 25
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        try:
            with open(port_file) as f:
                lines = f.read().split("\n")
            if len(lines) >= 2 and lines[0].strip().isdigit() and lines[1].strip():
                return proc, int(lines[0]), lines[1].strip()
        except OSError:
            pass
        time.sleep(0.1)
    try:
        proc.kill()
    except OSError:
        pass
    log.close()
    with open(log_path, "rb") as f:
        tail = f.read()[-3000:].decode("utf-8", "replace")
    return None, None, tail


def start_chrome(say, dim):
    """Starts Chromium. Returns (process, port, browser websocket path, headless)."""
    chrome = find_chrome()
    if not chrome:
        raise BrowserError(
            "I couldn't find a Chromium browser to drive.\n"
            "If you use the Cline extension in VS Code: ask Cline to open any web page with its browser\n"
            "once (that downloads its Chromium), then run Screen Agent again.\n"
            "Or set SCREEN_AGENT_CHROME to the path of a Chrome or Chromium program.")
    headless = os.environ.get("SCREEN_AGENT_HEADLESS") == "1" or os.environ.get("CODESPACES") == "true" \
        or not _has_display()
    os.makedirs(PROFILE, exist_ok=True)
    os.chmod(os.path.dirname(PROFILE), 0o700)
    log_path = os.path.join(os.path.dirname(PROFILE), "browser.log")
    attempts = [(headless, False)]
    if not headless:
        attempts.append((True, False))  # no usable window: fall back to running unseen with a live view
    attempts += [(h, True) for h, _ in list(attempts)]
    profile, last = PROFILE, ""
    for h, ns in attempts:
        proc, port, info = _launch(chrome, h, ns, profile, log_path)
        if proc:
            if ns:
                say(dim("(Chromium's own sandbox isn't available in this container, so it runs without it.)"))
            return proc, port, info, h
        last = info
        if "ProcessSingleton" in last or "profile appears to be in use" in last:
            profile = tempfile.mkdtemp(prefix="screen-agent-browser-")  # another copy holds the saved profile
    raise BrowserError("Chromium (%s) didn't start. Its last output:\n%s" % (chrome, last.strip()[-1500:]))


# --------------------------------------------------------------------------- DevTools protocol over a websocket

class WebSocket:
    """Just enough of RFC 6455 for a local DevTools connection: text frames, ping, close."""

    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n") % (u.path or "/", u.hostname, u.port, key)
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise BrowserError("The browser refused the DevTools connection.")
            head += chunk
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status + b" ":
            raise BrowserError("DevTools handshake failed: %s" % status.decode("latin-1"))
        self.buf = head.split(b"\r\n\r\n", 1)[1]
        self.sock.settimeout(None)
        self.send_lock = threading.Lock()

    def _exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(max(65536, n - len(self.buf)))
            if not chunk:
                raise BrowserError("The browser closed the connection.")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload):
        hdr = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload)) if n < 4096 else \
            (int.from_bytes(payload, "big") ^ int.from_bytes((mask * (n // 4 + 1))[:n], "big")).to_bytes(n, "big")
        with self.send_lock:
            self.sock.sendall(hdr + mask + masked)

    def send(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def recv(self):
        parts = []
        while True:
            b0, b1 = self._exact(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._exact(8))[0]
            mask = self._exact(4) if b1 & 0x80 else None
            data = self._exact(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise BrowserError("The browser closed the connection.")
            if opcode == 0x9:
                self._send_frame(0xA, data)
                continue
            if opcode in (0x1, 0x2, 0x0):
                parts.append(data)
                if b0 & 0x80:
                    return b"".join(parts).decode("utf-8")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class CDP:
    """One browser-level DevTools connection; tabs are reached through flattened sessions."""

    def __init__(self, url):
        self.ws = WebSocket(url)
        self.lock = threading.Lock()
        self.next_id = 0
        self.pending = {}
        self.handlers = {}
        self.closed = None
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while True:
                msg = json.loads(self.ws.recv())
                if "id" in msg:
                    slot = self.pending.get(msg["id"])
                    if slot:
                        slot[1] = msg
                        slot[0].set()
                elif "method" in msg:
                    h = self.handlers.get(msg["method"])
                    if h:
                        try:
                            h(msg.get("params") or {}, msg.get("sessionId"))
                        except Exception:  # noqa: BLE001 - a bad event must not stop the reader
                            pass
        except Exception as e:  # noqa: BLE001
            self.closed = str(e) or "The browser closed."
            for slot in list(self.pending.values()):
                slot[0].set()

    def call(self, method, params=None, session=None, timeout=30):
        if self.closed:
            raise BrowserError("The browser closed (%s)." % self.closed)
        with self.lock:
            self.next_id += 1
            mid = self.next_id
            slot = [threading.Event(), None]
            self.pending[mid] = slot
        msg = {"id": mid, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self.ws.send(json.dumps(msg))
        ok = slot[0].wait(timeout)
        self.pending.pop(mid, None)
        if not ok:
            raise BrowserError("The browser didn't answer %s in time." % method)
        if slot[1] is None:
            raise BrowserError("The browser closed (%s)." % self.closed)
        if "error" in slot[1]:
            raise BrowserError("%s: %s" % (method, slot[1]["error"].get("message", "failed")))
        return slot[1].get("result") or {}


# --------------------------------------------------------------------------- live view (for a browser nobody can see)

LIVE_PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Screen Agent live view</title>
<style>
:root{--bg:#f6f6f4;--surface:#fff;--ink:#1d1d1b;--muted:#5f5f5a;--line:#dcdcd6;--accent:#2f5bd3}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--surface:#1f1f1d;--ink:#ececE8;--muted:#a6a6a0;--line:#353532;--accent:#7d9cff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/20px system-ui,sans-serif}
main{max-width:1312px;margin:0 auto;padding:16px}
h1{font-size:16px;line-height:24px;font-weight:600;margin:0 0 4px}
p{margin:0 0 12px;color:var(--muted)}
.frame{background:var(--surface);border:1px solid var(--line);border-radius:8px;overflow:hidden}
img{display:block;width:100%;height:auto}
.state{color:var(--accent);font-weight:600}
</style></head><body><main>
<h1>Screen Agent live view</h1><p>What Claude sees and does in its browser. <span class="state" id="s">Connecting</span></p>
<div class="frame"><img id="v" alt="The agent's browser window"></div></main>
<script>
var v=document.getElementById('v'),s=document.getElementById('s'),busy=false;
function tick(){if(busy)return;busy=true;var n=new Image();n.onload=function(){v.src=n.src;s.textContent='Live';busy=false};
n.onerror=function(){s.textContent='Waiting for the agent';busy=false};n.src='/frame.jpg?'+Date.now();}
setInterval(tick,250);tick();
</script></body></html>"""


class LiveView:
    """Serves the latest screencast frame so the person can watch a browser that has no window."""

    def __init__(self, say, dim):
        self.frame = None
        view = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def address_string(self):
                return self.client_address[0]

            def do_GET(self):
                if self.path.startswith("/frame.jpg"):
                    data = view.frame
                    if not data:
                        self.send_response(503)
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                body = LIVE_PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
            allow_reuse_address = True

            def server_bind(self):  # no hostname lookup
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = self.server_address[0], self.server_address[1]

        self.server = None
        for port in [LIVE_PORT] + list(range(LIVE_PORT + 1, LIVE_PORT + 10)):
            try:
                self.server = Server(("127.0.0.1", port), Handler)
                break
            except OSError:
                continue
        if self.server:
            self.port = self.server.server_address[1]
            threading.Thread(target=self.server.serve_forever, daemon=True).start()
            hint = (" (VS Code will offer to open it; or use the Ports tab)"
                    if os.environ.get("CODESPACES") == "true" else "")
            say("Watch it work: open http://localhost:%d%s" % (self.port, hint))

    def close(self):
        if self.server:
            self.server.shutdown()


# --------------------------------------------------------------------------- the screen the agent drives

class BrowserScreen:
    """Answers the same calls as agent.Screen, but for a Chromium page instead of the desktop."""

    def __init__(self, shared, say, dim):
        self.g = shared  # glide_path, drag_duration, straight_path, Stopped, SMOOTH, TYPE_CHECK_EVERY
        self.say, self.dim = say, dim
        self.W, self.H, self.sw, self.sh = VIEW_W, VIEW_H, VIEW_W, VIEW_H
        self.pos = (VIEW_W // 2, VIEW_H // 2)
        self.buttons = 0  # held mouse buttons, CDP bitmask: left 1, right 2, middle 4
        self.mods = 0     # held modifier bits
        self.show_cursor = os.environ.get("SCREEN_AGENT_SHOW_CURSOR") != "0"
        self.proc, port, path, self.headless = start_chrome(say, dim)
        self.cdp = CDP("ws://127.0.0.1:%d%s" % (port, path))
        self.session = None
        self.target = None
        self.live = None
        if self.headless:
            self.live = LiveView(say, dim)
            self.cdp.handlers["Page.screencastFrame"] = self._frame
        pages = [t for t in self.cdp.call("Target.getTargets")["targetInfos"] if t["type"] == "page"]
        target = pages[0]["targetId"] if pages else self.cdp.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        self._attach(target)

    # ---- tabs

    def _frame(self, params, session):
        if session == self.session and self.live:
            self.live.frame = base64.b64decode(params.get("data", ""))
        try:
            self.cdp.ws.send(json.dumps({"id": 0, "method": "Page.screencastFrameAck",
                                         "params": {"sessionId": params.get("sessionId")}, "sessionId": session}))
        except Exception:  # noqa: BLE001
            pass

    def _attach(self, target_id):
        if self.session and self.live:
            try:
                self.cdp.call("Page.stopScreencast", session=self.session, timeout=5)
            except BrowserError:
                pass
        self.session = self.cdp.call("Target.attachToTarget", {"targetId": target_id, "flatten": True})["sessionId"]
        self.target = target_id
        s = self.session
        self.cdp.call("Page.enable", session=s)
        self.cdp.call("Runtime.enable", session=s)
        self.cdp.call("Emulation.setDeviceMetricsOverride",
                      {"width": VIEW_W, "height": VIEW_H, "deviceScaleFactor": 1, "mobile": False}, session=s)
        try:
            self.cdp.call("Target.activateTarget", {"targetId": target_id})
        except BrowserError:
            pass
        if self.live:
            self.cdp.call("Page.startScreencast", {"format": "jpeg", "quality": 70, "maxWidth": VIEW_W,
                                                   "maxHeight": VIEW_H, "everyNthFrame": 1}, session=s)
        self._draw_cursor()

    def _pages(self):
        return [t for t in self.cdp.call("Target.getTargets")["targetInfos"]
                if t["type"] == "page" and not t.get("url", "").startswith("devtools://")]

    def _tabs_text(self, note=""):
        lines = [note] if note else []
        lines.append("Open tabs:")
        for i, t in enumerate(self._pages(), 1):
            mark = "*" if t["targetId"] == self.target else " "
            lines.append("%s %d. %s | %s" % (mark, i, (t.get("title") or "(untitled)")[:80], t.get("url", "")[:200]))
        return "\n".join(lines)

    def _wait_loaded(self, timeout=20):
        end = time.time() + timeout
        time.sleep(0.2)
        while time.time() < end:
            try:
                r = self.cdp.call("Runtime.evaluate", {"expression": "document.readyState", "returnByValue": True},
                                  session=self.session, timeout=5)
                if r.get("result", {}).get("value") == "complete":
                    break
            except BrowserError:
                pass
            time.sleep(0.2)
        self._draw_cursor()

    @staticmethod
    def _url(u):
        u = str(u or "").strip()
        if not u:
            raise ValueError("url is required")
        if "://" not in u and not u.startswith(("about:", "data:")):
            u = "https://" + u
        return u

    def browser_action(self, inp):
        """Runs the custom `browser` tool. Returns text for the tool result."""
        action = str(inp.get("action", "")).strip()
        s = self.session
        if action == "navigate":
            r = self.cdp.call("Page.navigate", {"url": self._url(inp.get("url"))}, session=s)
            if r.get("errorText"):
                raise ValueError("Couldn't open that address: %s" % r["errorText"])
            self._wait_loaded()
            return self._tabs_text()
        if action in ("back", "forward"):
            h = self.cdp.call("Page.getNavigationHistory", session=s)
            idx = h["currentIndex"] + (-1 if action == "back" else 1)
            if not 0 <= idx < len(h["entries"]):
                return self._tabs_text("There's no page to go %s to." % action)
            self.cdp.call("Page.navigateToHistoryEntry", {"entryId": h["entries"][idx]["id"]}, session=s)
            self._wait_loaded()
            return self._tabs_text()
        if action == "reload":
            self.cdp.call("Page.reload", session=s)
            self._wait_loaded()
            return self._tabs_text()
        if action == "new_tab":
            url = self._url(inp.get("url")) if inp.get("url") else "about:blank"
            tid = self.cdp.call("Target.createTarget", {"url": url})["targetId"]
            self._attach(tid)
            self._wait_loaded()
            return self._tabs_text()
        if action in ("switch_tab", "close_tab"):
            pages = self._pages()
            try:
                n = int(inp.get("tab"))
            except (TypeError, ValueError):
                raise ValueError("tab must be a tab number from the list")
            if not 1 <= n <= len(pages):
                raise ValueError("There's no tab %d; there are %d." % (n, len(pages)))
            tid = pages[n - 1]["targetId"]
            if action == "switch_tab":
                self._attach(tid)
                return self._tabs_text()
            if len(pages) == 1:
                raise ValueError("That's the only tab, so it stays open.")
            self.cdp.call("Target.closeTarget", {"targetId": tid})
            time.sleep(0.2)
            if tid == self.target:
                rest = [t for t in self._pages() if t["targetId"] != tid]
                self._attach(rest[0]["targetId"])
            return self._tabs_text()
        if action == "list_tabs":
            return self._tabs_text()
        raise ValueError("Unknown browser action: %s" % action)

    # ---- geometry (screenshots are the page at 1:1, so these are identity maps)

    def to_screen(self, coord, name="coordinate"):
        if not isinstance(coord, (list, tuple)) or len(coord) != 2:
            raise ValueError("%s must be [x, y]" % name)
        x, y = float(coord[0]), float(coord[1])
        if not (math.isfinite(x) and math.isfinite(y)):
            raise ValueError("%s must be [x, y]" % name)
        return int(round(min(max(x, 0), VIEW_W - 1))), int(round(min(max(y, 0), VIEW_H - 1)))

    def to_shot(self, X, Y):
        return int(X), int(Y)

    # ---- pictures

    def screenshot(self):
        r = self.cdp.call("Page.captureScreenshot", {"format": "png", "fromSurface": True}, session=self.session)
        return base64.b64decode(r["data"])

    def zoom(self, region):
        if not isinstance(region, (list, tuple)) or len(region) != 4:
            raise ValueError("region must be [x0, y0, x1, y1]")
        x0, y0 = self.to_screen(region[:2], "region")
        x1, y1 = self.to_screen(region[2:], "region")
        x0, x1 = sorted((x0, x1))
        y0, y1 = sorted((y0, y1))
        w, h = max(1, x1 - x0), max(1, y1 - y0)
        scale = min(self.sw / float(w), self.sh / float(h))
        r = self.cdp.call("Page.captureScreenshot",
                          {"format": "png", "clip": {"x": x0, "y": y0, "width": w, "height": h, "scale": scale}},
                          session=self.session)
        return base64.b64decode(r["data"])

    # ---- pointer

    def cursor(self):
        return self.pos

    def cursor_or_none(self):
        return self.pos

    def _draw_cursor(self):
        if not self.show_cursor:
            return
        try:
            self.cdp.call("Runtime.evaluate", {"expression": CURSOR_JS % self.pos}, session=self.session, timeout=5)
        except BrowserError:
            pass

    def _mouse(self, kind, x, y, button="none", clicks=0, dx=0, dy=0):
        p = {"type": kind, "x": x, "y": y, "modifiers": self.mods, "buttons": self.buttons,
             "button": button, "clickCount": clicks}
        if kind == "mouseWheel":
            p["deltaX"], p["deltaY"] = dx, dy
        self.cdp.call("Input.dispatchMouseEvent", p, session=self.session)

    def move(self, X, Y):
        self.pos = (int(X), int(Y))
        self._mouse("mouseMoved", self.pos[0], self.pos[1], "left" if self.buttons & 1 else "none")
        self._draw_cursor()

    def glide(self, X, Y, drag_from=None):
        g = self.g
        dragging = drag_from is not None
        a = drag_from if dragging else self.pos
        if g["SMOOTH"]:
            d = math.hypot(X - a[0], Y - a[1])
            pts, dt = g["glide_path"](a, (X, Y), self.W, self.H, g["drag_duration"](d) if dragging else None)
        else:
            pts, dt = (g["straight_path"](a, (X, Y), 12), 0.015) if dragging else ([(X, Y)], 0.0)
        start = time.time()
        for i, (x, y) in enumerate(pts):
            self.move(int(round(x)), int(round(y)))
            if dt:  # keep to the clock: each step's own cost doesn't slow the glide
                wait = start + (i + 1) * dt - time.time()
                if wait > 0:
                    time.sleep(wait)

    BUTTONS = {1: ("left", 1), 2: ("middle", 4), 3: ("right", 2)}

    def button(self, b, down):
        name, bit = self.BUTTONS[b]
        if down:
            self.buttons |= bit
            self._mouse("mousePressed", self.pos[0], self.pos[1], name, 1)
        else:
            self.buttons &= ~bit
            self._mouse("mouseReleased", self.pos[0], self.pos[1], name, 1)

    def click(self, b, n):
        if b in (4, 5, 6, 7):  # scroll wheel: up, down, left, right
            dx = {6: -100, 7: 100}.get(b, 0)
            dy = {4: -100, 5: 100}.get(b, 0)
            for _ in range(n):
                self._mouse("mouseWheel", self.pos[0], self.pos[1], dx=dx, dy=dy)
                time.sleep(0.05)
            return
        name, bit = self.BUTTONS[b]
        for i in range(1, n + 1):
            self.buttons |= bit
            self._mouse("mousePressed", self.pos[0], self.pos[1], name, i)
            self.buttons &= ~bit
            self._mouse("mouseReleased", self.pos[0], self.pos[1], name, i)
            if i < n:
                time.sleep(0.06)

    # ---- keyboard

    def _key_def(self, name):
        low = name.lower()
        if low in NAMED:
            return NAMED[low]
        if len(name) == 1:
            ch = name
            if ch.isalpha() and ch.isascii():
                return (ch, "Key" + ch.upper(), ord(ch.upper()), ch)
            if ch.isdigit():
                return (ch, "Digit" + ch, ord(ch), ch)
            if ch in PUNCT_CODES:
                code, vk = PUNCT_CODES[ch]
                return (ch, code, vk, ch)
            return (ch, "", 0, ch)
        raise ValueError("Unknown key: %s" % name)

    def _key(self, kind, key, code, vk, text=""):
        p = {"type": kind, "key": key, "code": code, "windowsVirtualKeyCode": vk,
             "nativeVirtualKeyCode": vk, "modifiers": self.mods}
        if kind == "keyDown" and text and not (self.mods & (1 | 2 | 4)):
            p["text"] = text
            p["unmodifiedText"] = text
        elif kind == "keyDown":
            p["type"] = "rawKeyDown"
        self.cdp.call("Input.dispatchKeyEvent", p, session=self.session)

    def _press_mod(self, name, down):
        bit, key, code, vk = MODS[name.lower()]
        if down:
            self.mods |= bit
            self._key("keyDown", key, code, vk)
        else:
            self.mods &= ~bit
            self._key("keyUp", key, code, vk)

    def hold_mods(self, text):
        if not text:
            return []
        names = [p.strip() for p in str(text).split("+") if p.strip()]
        for n in names:
            if n.lower() not in MODS:
                raise ValueError("Unknown modifier: %s" % n)
        for n in names:
            self._press_mod(n, True)
        return names

    def release_mods(self, names):
        for n in reversed(names):
            self._press_mod(n, False)

    def release_all(self):
        try:
            for name, bit in (("left", 1), ("right", 2), ("middle", 4)):
                if self.buttons & bit:
                    self.buttons &= ~bit
                    self._mouse("mouseReleased", self.pos[0], self.pos[1], name, 1)
            for name in ("shift", "ctrl", "alt", "super"):
                if self.mods & MODS[name][0]:
                    self._press_mod(name, False)
        except BrowserError:
            pass

    def combo(self, text, repeat=1, hold=None):
        parts = [p.strip() for p in str(text).split("+")]
        if str(text).endswith("++"):
            parts = [p for p in parts if p] + ["+"]
        parts = [p for p in parts if p] if str(text) != "+" else ["+"]
        if not parts:
            raise ValueError("no key given")
        mods = [p for p in parts[:-1]]
        for m in mods:
            if m.lower() not in MODS:
                raise ValueError("Unknown modifier: %s" % m)
        last = parts[-1]
        try:
            for _ in range(max(1, min(100, int(repeat)))):
                for m in mods:
                    self._press_mod(m, True)
                if last.lower() in MODS:
                    self._press_mod(last, True)
                    if hold:
                        time.sleep(hold)
                    self._press_mod(last, False)
                else:
                    key, code, vk, txt = self._key_def(last)
                    if self.mods & 2 and len(key) == 1 and key.isalpha():
                        key, txt = key.lower(), key.lower()
                    self._key("keyDown", key, code, vk, txt)
                    if hold:
                        time.sleep(hold)
                    self._key("keyUp", key, code, vk)
                for m in reversed(mods):
                    self._press_mod(m, False)
                time.sleep(0.03)
        finally:
            self.release_all()

    def type_text(self, text, pause=0.0, should_stop=None):
        """Types one character at a time, `pause` seconds apart, keeping to the clock."""
        chars = [ch for ch in text if ch != "\r"]
        start = time.time()
        every = self.g["TYPE_CHECK_EVERY"]
        for i, ch in enumerate(chars):
            if should_stop is not None and i and i % every == 0 and should_stop():
                raise self.g["Stopped"]()
            if ch == "\n":
                self._key("keyDown", "Enter", "Enter", 13, "\r")
                self._key("keyUp", "Enter", "Enter", 13)
            elif ch == "\t":
                self._key("keyDown", "Tab", "Tab", 9)
                self._key("keyUp", "Tab", "Tab", 9)
            else:
                key, code, vk, _ = self._key_def(ch) if len(ch) == 1 else (ch, "", 0, ch)
                self._key("keyDown", key, code, vk, ch)
                self._key("keyUp", key, code, vk)
            if pause:
                wait = start + (i + 1) * pause - time.time()
                if wait > 0:
                    time.sleep(wait)

    def close(self):
        if self.live:
            self.live.close()
        try:
            self.cdp.ws.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.proc.terminate()
            self.proc.wait(5)
        except Exception:  # noqa: BLE001
            try:
                self.proc.kill()
            except Exception:  # noqa: BLE001
                pass
