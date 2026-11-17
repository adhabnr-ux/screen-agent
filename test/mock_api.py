#!/usr/bin/env python3
"""Mock of the Anthropic Messages API for testing Screen Agent offline.

Plays a scripted computer-use session and checks every request against SPEC.md.
Writes a JSON report to $MOCK_REPORT (default ./mock_report.json) after each request.

  python3 test/mock_api.py --port 8765
  SCREEN_AGENT_BASE_URL=http://127.0.0.1:8765 ANTHROPIC_API_KEY=sk-test-good ...

Options via env:
  MOCK_REJECT_BETA=1   reply 400 to any request carrying anthropic-beta (tests compat mode)
  MOCK_429_FIRST=1     reply 429 (retry-after: 1) to the first /v1/messages call
"""
import argparse
import base64
import json
import os
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GOOD_KEY = "sk-test-good"
REPORT = os.environ.get("MOCK_REPORT", "mock_report.json")
state = {"calls": 0, "step": 0, "errors": [], "checks": [], "saw_429": False,
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


def tu(i, name, inp):
    return {"type": "tool_use", "id": f"toolu_{state['step']}_{i}", "name": name,
            "toolset_name": "computer", "input": inp}


SIG = "c2lnbmF0dXJl"  # fake signature, must be echoed back unchanged


def script(step):
    """Assistant content for each step of the scripted session."""
    if step == 0:
        return [{"type": "thinking", "thinking": "Looking at the screen first.", "signature": SIG},
                {"type": "text", "text": "I'll take a screenshot to see the screen."},
                tu(0, "screenshot", {})], "tool_use"
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
    return [{"type": "thinking", "thinking": "", "signature": SIG},
            {"type": "text", "text": "Done. I ran every action in the test batch."}], "end_turn"


def validate(body, headers):
    check(headers.get("x-api-key") == GOOD_KEY, "x-api-key header is the test key")
    check(headers.get("anthropic-version") == "2026-10-21", "anthropic-version 2026-10-21")
    check(body.get("model"), "model set")
    check(body.get("max_tokens", 0) >= 1024, "max_tokens >= 1024")
    tools = body.get("tools")
    check(tools == [{"type": "computer_toolset_20260801"}], "tools is exactly the computer toolset")
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
        for r in results:
            check(r.get("toolset_name") == "computer", f"{r['tool_use_id']}: toolset_name echoed")
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


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj, extra=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            if self.headers.get("x-api-key") == GOOD_KEY:
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
        msgs = validate(body, hdrs)
        if state["step"] > 0:
            check_results(msgs)
        content, stop = script(state["step"])
        state["step"] += 1
        if stop == "end_turn":
            state["done"] = True
        write_report()
        self.send(200, {"id": f"msg_{state['calls']}", "type": "message", "role": "assistant",
                        "model": body.get("model"), "content": content, "stop_reason": stop,
                        "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 10}})


def write_report():
    with open(REPORT, "w") as f:
        json.dump({"done": state["done"], "calls": state["calls"], "errors": state["errors"],
                   "passed": len(state["checks"]), "saw_429": state["saw_429"],
                   "compat": state["compat"], "image_sizes": state["image_sizes"]}, f, indent=1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    write_report()
    print(f"mock api on http://{a.host}:{a.port}", flush=True)
    ThreadingHTTPServer((a.host, a.port), H).serve_forever()
