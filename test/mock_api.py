#!/usr/bin/env python3
"""Mock of the Anthropic Messages API for testing Screen Agent offline.

Plays a scripted computer-use session and checks every request against SPEC.md.
Writes a JSON report to $MOCK_REPORT (default ./mock_report.json) after each request.

  python3 test/mock_api.py --port 8765
  SCREEN_AGENT_BASE_URL=http://127.0.0.1:8765 ANTHROPIC_API_KEY=sk-test-good ...

Options via env:
  MOCK_REJECT_BETA=1   reply 400 to any request carrying anthropic-beta (tests compat mode)
  MOCK_429_FIRST=1     reply 429 (retry-after: 1) to the first /v1/messages call
  MOCK_SCRIPT=<file>   play this JSON instead of the built-in session: a list of turns, each a list of
                       {"name": ..., "input": {...}} computer actions; after the last turn the mock ends.
                       Results are checked only generically (pairing, toolset_name); "action_errors" in the
                       report counts tool results that came back with is_error.
                       A turn may also call the custom "browser" tool (browser mode). Text results of
                       every tool_result are kept in the report's "result_texts" for tests to check.
  MOCK_REJECT_SPEED=1  reply 400 to any request with "speed" in the body (tests the fast-mode fallback)
  MOCK_UNSCOPED=1      the key is organization-wide: requests need anthropic-workspace-id
                       (wrkspc_01TESTDEFAULT or wrkspc_01TESTSECOND); /v1/organizations/workspaces lists both
  MOCK_EXTRA_WORKSPACE=<id>  with MOCK_UNSCOPED: also accept this workspace ID (not listed)
  MOCK_SCOPED_STRICT=1 the key is tied to one workspace: any anthropic-workspace-id header gets 403
  MOCK_UNSCOPED=nolist same, but listing workspaces returns 403 (user must paste the ID)
"""
import argparse
import base64
import json
import os
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GOOD_KEY = "sk-test-good"
UNSCOPED = os.environ.get("MOCK_UNSCOPED", "")
WORKSPACES = [{"id": "wrkspc_01TESTDEFAULT", "type": "workspace", "name": "Default Workspace", "archived_at": None},
              {"id": "wrkspc_01TESTSECOND", "type": "workspace", "name": "Research", "archived_at": None},
              {"id": "wrkspc_01TESTARCHIVED", "type": "workspace", "name": "Old", "archived_at": "2026-01-01T00:00:00Z"}]
LIVE_IDS = [w["id"] for w in WORKSPACES if not w["archived_at"]]
if os.environ.get("MOCK_EXTRA_WORKSPACE"):
    LIVE_IDS.append(os.environ["MOCK_EXTRA_WORKSPACE"])
NEED_WS = {"type": "error", "error": {"type": "invalid_request_error", "message":
           "This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id "
           "header with the ID of the workspace to use. Add the header, or use an API key that is scoped to a workspace."}}
REPORT = os.environ.get("MOCK_REPORT", "mock_report.json")
INPUT_MEMBERS = ["left_click", "right_click", "middle_click", "double_click", "triple_click", "left_click_drag",
                 "mouse_move", "left_mouse_down", "left_mouse_up", "scroll", "type", "key", "hold_key"]
state = {"browser_mode": False, "result_texts": [], "action_errors": [], "guide": False, "speed": None, "speed_rejected": False, "workspace_seen": None, "calls": 0, "step": 0, "errors": [], "checks": [], "saw_429": False,
         "compat": False, "done": False, "image_sizes": []}


def check(ok, msg):
    (state["checks"] if ok else state["errors"]).append(msg)


def image_size(b64, media):
    raw = base64.b64decode(b64)
    if media == "image/png":
        if raw[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("not a PNG")
        return struct.unpack(">II", raw[16:24])
    if media == "image/jpeg":
        if raw[:2] != b"\xff\xd8":
            raise ValueError("not a JPEG")
        i = 2
        while i < len(raw):
            if raw[i] != 0xFF:
                i += 1
                continue
            marker = raw[i + 1]
            if marker in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", raw[i + 5:i + 9])
                return w, h
            seg = struct.unpack(">H", raw[i + 2:i + 4])[0]
            i += 2 + seg
        raise ValueError("no SOF in JPEG")
    raise ValueError("unsupported media " + media)


CUSTOM_TOOLS = {"browser"}  # user-defined tools: their tool_use blocks carry no toolset_name


def tu(i, name, inp):
    b = {"type": "tool_use", "id": f"toolu_{state['step']}_{i}", "name": name, "input": inp}
    if name not in CUSTOM_TOOLS:
        b["toolset_name"] = "computer"
    return b


SIG = "c2lnbmF0dXJl"  # fake signature, must be echoed back unchanged


CUSTOM = None
if os.environ.get("MOCK_SCRIPT"):
    with open(os.environ["MOCK_SCRIPT"]) as _f:
        CUSTOM = json.load(_f)


def script(step):
    """Assistant content for each step of the scripted session."""
    if CUSTOM is not None:
        if step < len(CUSTOM):
            return [{"type": "text", "text": "Step %d." % (step + 1)}] + \
                   [tu(i, a["name"], a.get("input", {})) for i, a in enumerate(CUSTOM[step])], "tool_use"
        return [{"type": "text", "text": "Done."}], "end_turn"
    if step == 0:
        return [{"type": "thinking", "thinking": "Looking at the screen first.", "signature": SIG},
                {"type": "text", "text": "I'll take a screenshot to see the screen."},
                tu(0, "screenshot", {})], "tool_use"
    if state["guide"] and step >= 1:
        return [{"type": "text", "text": "Click the Apple menu in the top-left corner, then tell me when it's open."}], "end_turn"
    if step == 1:
        return [{"type": "text", "text": "Running a batch of actions."},
                tu(0, "mouse_move", {"coordinate": [200, 150]}),
                tu(1, "left_click", {"coordinate": [210, 160]}),
                tu(2, "double_click", {"coordinate": [220, 170], "text": "shift"}),
                tu(3, "right_click", {}),
                tu(4, "type", {"text": "héllo wörld\nline2"}),
                tu(5, "key", {"text": "ctrl+a"}),
                tu(6, "key", {"text": "Return", "repeat": 2}),
                tu(7, "scroll", {"scroll_direction": "down", "scroll_amount": 3, "coordinate": [300, 300]}),
                tu(8, "left_click_drag", {"start_coordinate": [100, 100], "coordinate": [200, 200]}),
                tu(9, "zoom", {"region": [0, 0, 400, 250]}),
                tu(10, "cursor_position", {}),
                tu(11, "wait", {"duration": 0.2}),
                tu(12, "hold_key", {"text": "shift", "duration": 0.1}),
                tu(13, "left_mouse_down", {}),
                tu(14, "left_mouse_up", {}),
                tu(15, "triple_click", {"coordinate": [50, 50]}),
                tu(16, "middle_click", {"coordinate": [60, 60]}),
                tu(17, "frobnicate", {}),
                tu(18, "screenshot", {})], "tool_use"
    if step == 2:  # batch without a trailing screenshot: the agent must attach one itself
        return [{"type": "text", "text": "Typing into the field."},
                tu(0, "left_click", {"coordinate": [300, 300]}),
                tu(1, "type", {"text": "abc"})], "tool_use"
    if step == 3:  # batch that ends with screenshot: nothing extra attached
        return [tu(0, "key", {"text": "Return"}),
                tu(1, "screenshot", {})], "tool_use"
    return [{"type": "thinking", "thinking": "", "signature": SIG},
            {"type": "text", "text": "Done. I ran every action in the test batch."}], "end_turn"


def validate(body, headers):
    check(headers.get("x-api-key") == GOOD_KEY, "x-api-key header is the test key")
    check(headers.get("anthropic-version") == "2026-10-21", "anthropic-version 2026-10-21")
    check(body.get("model"), "model set")
    check(body.get("max_tokens", 0) >= 1024, "max_tokens >= 1024")
    tools = body.get("tools")
    extra = tools[1:] if isinstance(tools, list) else []
    browser_tool = len(extra) == 1 and extra[0].get("name") == "browser" and "type" not in extra[0] \
        and extra[0].get("input_schema", {}).get("type") == "object" \
        and "action" in extra[0]["input_schema"].get("required", [])
    if browser_tool:
        state["browser_mode"] = True
    ok_tools = isinstance(tools, list) and len(tools) in (1, 2) and tools[0].get("type") == "computer_toolset_20260801" \
        and set(tools[0]) <= {"type", "configs"} and (len(tools) == 1 or browser_tool)
    check(ok_tools, "tools is the computer toolset (plus the browser tool in browser mode)")
    if ok_tools and "configs" in tools[0]:
        cfg = tools[0]["configs"]
        state["guide"] = True
        check(sorted(cfg) == sorted(INPUT_MEMBERS) and all(v == {"enabled": False} for v in cfg.values()),
              "guide mode disables exactly the 13 input members")
        check("cannot control it" in body.get("system", ""), "guide-mode system prompt")
    if "speed" in body:
        state["speed"] = body["speed"]
        check(body["speed"] == "fast", "speed is 'fast' when present")
    check("Work in batches" in body.get("system", "") or state["guide"], "system prompt has the batching guidance")
    check("ordinary punctuation" in body.get("system", ""), "system prompt has the writing-style rule")
    check(body.get("thinking", {}).get("type") == "adaptive", "adaptive thinking")
    check("temperature" not in body and "top_p" not in body, "no sampling params")
    check(isinstance(body.get("system"), str) and "Screenshots are" in body["system"], "system prompt present")
    msgs = body.get("messages", [])
    check(len(msgs) >= 1 and msgs[0]["role"] == "user", "first message is user")
    # Alternation and tool_use/tool_result pairing
    for i in range(1, len(msgs)):
        if msgs[i]["role"] == msgs[i - 1]["role"]:
            check(False, f"messages {i-1},{i} share role {msgs[i]['role']}")
    for i, m in enumerate(msgs):
        if m["role"] != "assistant":
            continue
        uses = [b for b in m["content"] if b.get("type") == "tool_use"]
        if not uses:
            continue
        if i + 1 >= len(msgs):
            check(False, "assistant tool_use is last message (results missing)")
            continue
        results = [b for b in msgs[i + 1]["content"] if isinstance(b, dict) and b.get("type") == "tool_result"]
        ids = [r["tool_use_id"] for r in results]
        check(ids == [u["id"] for u in uses], f"msg {i}: one tool_result per tool_use, in order")
        by_id = {u["id"]: u for u in uses}
        for r in results:
            u = by_id.get(r["tool_use_id"], {})
            if u.get("toolset_name"):
                check(r.get("toolset_name") == u["toolset_name"], f"{r['tool_use_id']}: toolset_name echoed")
            else:
                check("toolset_name" not in r, f"{r['tool_use_id']}: no toolset_name on a custom tool's result")
        # thinking blocks echoed unchanged
        for b in m["content"]:
            if b.get("type") == "thinking":
                check(b.get("signature") == SIG, "thinking signature echoed unchanged")
    return msgs


def check_results(msgs):
    """Check the tool results of the latest user message against the scripted step."""
    last = msgs[-1]
    res = {r["tool_use_id"]: r for r in last["content"] if isinstance(r, dict) and r.get("type") == "tool_result"}

    def img(r, label):
        c = r.get("content")
        if r.get("is_error") or not isinstance(c, list) or c[0].get("type") != "image":
            check(False, f"{label}: expected image, got {json.dumps(r)[:200]}")
            return None
        src = c[0]["source"]
        try:
            w, h = image_size(src["data"], src["media_type"])
        except Exception as e:  # noqa
            check(False, f"{label}: bad image: {e}")
            return None
        state["image_sizes"].append([label, w, h])
        check(w <= 1280 and h <= 800, f"{label}: {w}x{h} fits 1280x800")
        return w, h

    if state["step"] == 1:
        img(res["toolu_0_0"], "screenshot")
    if state["step"] == 2:
        for k in range(0, 17):
            r = res[f"toolu_1_{k}"]
            if k == 9:
                img(r, "zoom")
            elif k == 10:
                txt = r["content"][0]["text"] if isinstance(r["content"], list) else r["content"]
                ok = "," in txt and all(p.strip().lstrip("-").isdigit() for p in txt.split(",")[:2])
                check(ok and not r.get("is_error"), f"cursor_position returns 'x,y' text (got {txt!r})")
            else:
                check(not r.get("is_error"), f"toolu_1_{k} succeeded ({json.dumps(r.get('content'))[:120]})")
        r = res["toolu_1_17"]
        check(r.get("is_error") is True, "unknown member -> is_error")
        r = res["toolu_1_18"]
        check(r.get("is_error") is True and "Not executed" in str(r.get("content")),
              "action after a failure -> Not executed")
        for k in list(range(0, 9)) + list(range(10, 17)):
            c = res[f"toolu_1_{k}"].get("content")
            check(not (isinstance(c, list) and any(b.get("type") == "image" for b in c)),
                  f"toolu_1_{k}: no screenshot attached to a failed batch")

    def kinds(r):
        c = r.get("content")
        return [b.get("type") for b in c] if isinstance(c, list) else ["text"]

    if state["step"] == 3 and not state["guide"]:
        check(kinds(res["toolu_2_0"]) == ["text"], "auto-screenshot: first result of the batch is plain OK")
        r = res["toolu_2_1"]
        check(kinds(r) == ["text", "text", "image"] and not r.get("is_error"),
              f"auto-screenshot: last result is [OK, label, image] (got {kinds(r)})")
        if kinds(r)[-1:] == ["image"]:
            check(r["content"][1]["text"] == "Screenshot after these actions:", "auto-screenshot label text")
            src = r["content"][2]["source"]
            w, h = image_size(src["data"], src["media_type"])
            state["image_sizes"].append(["auto", w, h])
            check(w <= 1280 and h <= 800, f"auto-screenshot {w}x{h} fits 1280x800")
    if state["step"] == 4 and not state["guide"]:
        check(kinds(res["toolu_3_0"]) == ["text"], "batch ending in screenshot: nothing attached to the key result")
        check(kinds(res["toolu_3_1"]) == ["image"], "batch ending in screenshot: screenshot result is one image")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def address_string(self):  # no reverse lookups
        return self.client_address[0]

    def send(self, code, obj, extra=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def workspace_problem(self):
        """None if the workspace header is fine for this key, else (code, body) to send."""
        ws = self.headers.get("anthropic-workspace-id")
        if os.environ.get("MOCK_SCOPED_STRICT") and ws:
            return 403, {"type": "error", "error": {"type": "permission_error",
                                                    "message": "This API key cannot be used with the requested workspace."}}
        if not UNSCOPED:
            return None
        if not ws:
            return 400, NEED_WS
        if ws not in LIVE_IDS:
            return 404, {"type": "error", "error": {"type": "not_found_error", "message": f"Workspace {ws} not found."}}
        state["workspace_seen"] = ws
        return None

    def do_GET(self):
        if self.path.startswith("/v1/organizations/workspaces"):
            if self.headers.get("x-api-key") != GOOD_KEY:
                return self.send(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            if UNSCOPED == "nolist":
                return self.send(403, {"type": "error", "error": {"type": "permission_error", "message": "Your account does not have permission to list workspaces."}})
            data = WORKSPACES if "include_default=true" in self.path else WORKSPACES[1:]
            return self.send(200, {"data": data, "has_more": False, "first_id": data[0]["id"], "last_id": data[-1]["id"]})
        if self.path.startswith("/v1/models"):
            if self.headers.get("x-api-key") == GOOD_KEY:
                wp = self.workspace_problem()
                if wp:
                    return self.send(*wp)
                return self.send(200, {"data": [{"id": "claude-opus-5-5"}]})
            return self.send(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
        self.send(404, {})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(n)
        if self.path != "/v1/messages":
            return self.send(404, {})
        state["calls"] += 1
        try:
            body = json.loads(raw)
        except Exception as e:  # noqa
            check(False, f"request body is not valid JSON: {e}")
            write_report()
            return self.send(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "bad json"}})
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        if os.environ.get("MOCK_429_FIRST") and not state["saw_429"]:
            state["saw_429"] = True
            return self.send(429, {"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}},
                             {"retry-after": "1"})
        if os.environ.get("MOCK_REJECT_BETA") and "anthropic-beta" in hdrs:
            return self.send(400, {"type": "error", "error": {"type": "invalid_request_error",
                                                              "message": "Unexpected value for anthropic-beta header"}})
        if os.environ.get("MOCK_REJECT_BETA"):
            state["compat"] = True
            check("fallbacks" not in body, "compat mode drops fallbacks")
        if os.environ.get("MOCK_REJECT_SPEED") and "speed" in body:
            state["speed_rejected"] = True
            return self.send(400, {"type": "error", "error": {"type": "invalid_request_error",
                                                              "message": "speed: fast mode is not available for this organization"}})
        wp = self.workspace_problem()
        if wp:
            check(False, "messages request without a valid anthropic-workspace-id for an unscoped key")
            write_report()
            return self.send(*wp)
        msgs = validate(body, hdrs)
        if CUSTOM is not None:
            last = msgs[-1]["content"] if msgs and msgs[-1]["role"] == "user" else []
            for r in last:
                if isinstance(r, dict) and r.get("type") == "tool_result":
                    if r.get("is_error"):
                        state["action_errors"].append(str(r.get("content"))[:200])
                    c = r.get("content")
                    for blk in (c if isinstance(c, list) else [{"type": "text", "text": c}]):
                        if isinstance(blk, dict) and blk.get("type") == "text":
                            state["result_texts"].append(blk.get("text", ""))
        elif state["step"] > 0:
            check_results(msgs)
        content, stop = script(state["step"])
        state["step"] += 1
        if stop == "end_turn":
            state["done"] = True
        write_report()
        self.send(200, {"id": f"msg_{state['calls']}", "type": "message", "role": "assistant",
                        "model": body.get("model"), "content": content, "stop_reason": stop,
                        "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 10}})


class Server(ThreadingHTTPServer):
    """HTTPServer.server_bind looks up this machine's network name, which is slow and makes
    macOS ask to "find devices on local networks". The mock only ever serves 127.0.0.1."""

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[0], self.server_address[1]


def write_report():
    with open(REPORT, "w") as f:
        json.dump({"done": state["done"], "calls": state["calls"], "errors": state["errors"],
                   "passed": len(state["checks"]), "saw_429": state["saw_429"],
                   "compat": state["compat"], "workspace": state["workspace_seen"], "guide": state["guide"], "speed": state["speed"],
                   "speed_rejected": state["speed_rejected"], "action_errors": state["action_errors"],
                   "custom": CUSTOM is not None, "browser_mode": state["browser_mode"],
                   "result_texts": state["result_texts"], "image_sizes": state["image_sizes"]}, f, indent=1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    write_report()
    print(f"mock api on http://{a.host}:{a.port}", flush=True)
    Server((a.host, a.port), H).serve_forever()
