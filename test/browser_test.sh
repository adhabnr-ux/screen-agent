#!/bin/bash
# Browser-mode tests. Runs inside test/browser_Dockerfile with the repo mounted at /src:
#   docker build -t screen-agent-browser-test -f test/browser_Dockerfile test
#   docker run --rm -v "$PWD":/src:ro screen-agent-browser-test bash /src/test/browser_test.sh
# Also runs on a GitHub ubuntu runner (SRC=$PWD). Real Chromium, real input events, no display
# (so the live view is tested too), the agent driven by test/mock_api.py.
set -u
SRC="${SRC:-/src}"
W="$(mktemp -d)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
unset DISPLAY WAYLAND_DISPLAY

python3 "$SRC/test/browser_pages.py" --port 8900 --log "$W/pagelog.jsonl" &
for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8900/test.html && break; sleep 0.1; done

cat > "$W/script.json" <<'EOF'
[
 [{"name": "browser", "input": {"action": "navigate", "url": "http://127.0.0.1:8900/test.html"}}],
 [{"name": "left_click", "input": {"coordinate": [300, 120]}},
  {"name": "type", "input": {"text": "Hello world, café."}}],
 [{"name": "left_click_drag", "input": {"start_coordinate": [120, 300], "coordinate": [520, 300]}}],
 [{"name": "scroll", "input": {"scroll_direction": "down", "scroll_amount": 3, "coordinate": [640, 400]}}],
 [{"name": "browser", "input": {"action": "new_tab", "url": "http://127.0.0.1:8900/page2.html"}},
  {"name": "browser", "input": {"action": "list_tabs"}}],
 [{"name": "browser", "input": {"action": "switch_tab", "tab": 1}},
  {"name": "zoom", "input": {"region": [0, 0, 640, 400]}}],
 [{"name": "browser", "input": {"action": "close_tab", "tab": 2}}]
]
EOF

run_session() { # $1 name, $2 port, rest: env for the agent
  local name=$1 port=$2; shift 2
  MOCK_SCRIPT="$W/script.json" MOCK_REPORT="$W/$name.json" python3 "$SRC/test/mock_api.py" --port "$port" >/dev/null 2>&1 &
  local mock=$!
  for i in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
  env "$@" SCREEN_AGENT_MODE=browser SCREEN_AGENT_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-test-good \
    SCREEN_AGENT_TASK="browser test" timeout 180 python3 "$SRC/linux/agent.py" > "$W/$name.out" 2>&1
  echo "exit=$?" >> "$W/$name.out"
  kill $mock 2>/dev/null
}

echo "=== 1. full browser session: navigate, click, type, drag, scroll, tabs, zoom (live view on)"
# poll the live view while the session runs
( for i in $(seq 600); do
    if curl -s -o "$W/frame.jpg" -w '%{http_code}' http://127.0.0.1:8890/frame.jpg 2>/dev/null | grep -q 200; then
      curl -s http://127.0.0.1:8890/ > "$W/live.html"; echo ok > "$W/live.ok"; break; fi
    sleep 0.2; done ) &
POLL=$!
START=$(date +%s.%N)
run_session full 8801
wait $POLL 2>/dev/null
sed 's/^/  | /' "$W/full.out" | grep -vE "→ (left_click|type|scroll|zoom|left_click_drag)" | head -30
python3 "$SRC/test/check_report.py" "$W/full.json" > "$W/check.txt"; RC=$?
[ "$RC" = 0 ] && pass "session finished: done, errors [], action_errors []" \
  || { fail "mock report"; python3 -c "import json,sys;r=json.load(open(sys.argv[1]));print('  done=%s errors=%s action_errors=%s passed=%s' % (r['done'], r['errors'][:5], r['action_errors'][:5], r['passed']))" "$W/full.json"; }
python3 - "$W/full.json" "$W/pagelog.jsonl" <<'PY' || FAIL=1
import json, sys
r = json.load(open(sys.argv[1]))
log = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
bad = 0
def ok(c, m):
    global bad
    print(("PASS: " if c else "FAIL: ") + m)
    bad += 0 if c else 1
ok(r.get("browser_mode"), "requests carried the browser tool next to the computer toolset")
inputs = [e for e in log if e.get("event") == "input"]
want = "Hello world, café."
ok(inputs and inputs[-1]["value"] == want, "typed text arrived exactly: %r" % (inputs[-1]["value"] if inputs else None))
ok(len(inputs) == len(want), "one input event per character (%d of %d)" % (len(inputs), len(want)))
if len(inputs) > 2:
    gaps = [(b["t"] - a["t"]) / 1000.0 for a, b in zip(inputs, inputs[1:])]
    avg = sum(gaps) / len(gaps)
    ok(abs(avg - 0.1091) <= 0.1091 * 0.25, "typing pace: average %.3f s between characters (110 wpm = 0.109 s)" % avg)
downs = [e for e in log if e.get("event") == "down"]
ok(downs and downs[0]["movesBefore"] >= 8, "pointer glided to the text box: %s mouse moves before the first click"
   % (downs[0]["movesBefore"] if downs else None))
ok(downs and downs[0]["cursorShown"], "the visible pointer is drawn on the page")
ok(downs and (downs[0]["x"], downs[0]["y"]) == (300, 120), "click landed at (300, 120): got %s"
   % (str((downs[0]["x"], downs[0]["y"])) if downs else "nothing"))
drags = [e for e in log if e.get("event") == "drag"]
ok(drags and abs(drags[0]["dx"] - 400) <= 2 and abs(drags[0]["dy"]) <= 2,
   "drag moved the handle by (%s, %s); expected (400, 0)" % ((drags[0]["dx"], drags[0]["dy"]) if drags else (None, None)))
ok(drags and drags[0]["moves"] >= 8, "drag passed through %s moves with the button held" % (drags[0]["moves"] if drags else None))
scrolls = [e for e in log if e.get("event") == "scroll"]
ok(scrolls and scrolls[-1]["y"] >= 200, "scroll moved the page down %s px" % (scrolls[-1]["y"] if scrolls else None))
ok(any(e.get("page") == "page2" for e in log), "new tab loaded the second page")
texts = r.get("result_texts", [])
tabs = [t for t in texts if t.startswith("Open tabs:")]
ok(len(tabs) >= 4, "browser tool returned the tab list each time (%d)" % len(tabs))
ok(any("* 2." in t and "Second page" in t for t in tabs), "after new_tab the second tab is current")
ok(any("* 1." in t and "2." in t for t in tabs), "after switch_tab 1 the first tab is current")
ok(tabs and "2." not in tabs[-1] and "* 1." in tabs[-1], "close_tab 2 left one tab open")
autos = sum(1 for t in texts if t == "Screenshot after these actions:")
ok(autos >= 5, "a screenshot came back after each batch (%d)" % autos)
sys.exit(1 if bad else 0)
PY
[ -s "$W/live.ok" ] && head -c 2 "$W/frame.jpg" | od -An -tx1 | grep -q "ff d8" \
  && pass "live view served a JPEG frame while Claude worked" || fail "live view didn't serve a frame"
grep -q "Screen Agent live view" "$W/live.html" 2>/dev/null && pass "live view page served" || fail "live view page"
grep -q "Watch it work: open http://localhost:8890" "$W/full.out" && pass "agent printed the live-view address" \
  || fail "no live-view address printed"

echo "=== 2. finds the Chromium that the Cline extension downloaded (nothing on PATH)"
REAL=$(python3 -c "import shutil,os;p=shutil.which('chromium') or shutil.which('google-chrome');print(os.path.realpath(p) if p else '')")
CHR=$( [ -x /usr/lib/chromium/chromium ] && echo /usr/lib/chromium/chromium || echo "$REAL" )
FAKEHOME="$W/home"
CL="$FAKEHOME/.vscode-remote/data/User/globalStorage/saoudrizwan.claude-dev/puppeteer/.chromium-browser-snapshots/linux-1234/chrome-linux"
mkdir -p "$CL" && ln -s "$CHR" "$CL/chrome"
mkdir -p "$W/bin"; for t in curl python3 env timeout; do ln -sf "$(command -v $t)" "$W/bin/$t"; done
cat > "$W/script.json" <<'EOF'
[[{"name": "browser", "input": {"action": "navigate", "url": "http://127.0.0.1:8900/page2.html"}}]]
EOF
run_session cline 8802 HOME="$FAKEHOME" PATH="$W/bin"
python3 "$SRC/test/check_report.py" "$W/cline.json" > /dev/null && pass "session ran with Cline's Chromium" \
  || { fail "Cline Chromium session"; python3 -c "import json,sys;r=json.load(open(sys.argv[1]));print('  done=%s errors=%s action_errors=%s passed=%s' % (r['done'], r['errors'][:5], r['action_errors'][:5], r['passed']))" "$W/cline.json"; }

echo "=== 3. no Chromium anywhere -> a clear message"
run_session none 8803 HOME="$W/empty" PATH="$W/bin"
grep -q "couldn't find a Chromium browser" "$W/none.out" && grep -q "exit=2" "$W/none.out" \
  && pass "clear message, exit 2" || { fail "missing-browser message"; cat "$W/none.out"; }

echo "=== 4. typing speed 0 and the pointer setting off still work"
cat > "$W/script.json" <<'EOF'
[[{"name": "browser", "input": {"action": "navigate", "url": "http://127.0.0.1:8900/test.html"}}],
 [{"name": "left_click", "input": {"coordinate": [300, 120]}}, {"name": "type", "input": {"text": "fast"}}]]
EOF
: > "$W/pagelog.jsonl"
run_session quick 8804 SCREEN_AGENT_WPM=0 SCREEN_AGENT_SMOOTH=0
python3 - "$W/pagelog.jsonl" <<'PY' && pass "WPM=0 and SMOOTH=0: text arrived, pointer jumped" || { fail "WPM=0/SMOOTH=0"; FAIL=1; }
import json, sys
log = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
inputs = [e for e in log if e.get("event") == "input"]
downs = [e for e in log if e.get("event") == "down"]
assert inputs and inputs[-1]["value"] == "fast", inputs
assert downs and downs[0]["movesBefore"] <= 2, downs
assert (inputs[-1]["t"] - inputs[0]["t"]) < 300, "too slow for WPM=0"
PY

if [ "$FAIL" = 0 ]; then echo "ALL BROWSER TESTS PASSED"; else echo "SOME BROWSER TESTS FAILED"; fi
exit $FAIL
