#!/bin/bash
# Runs inside the linux_Dockerfile container with the repo mounted at /src.
#   docker build -t screen-agent-linux-test -f test/linux_Dockerfile test
#   docker run --rm -v "$PWD":/src:ro screen-agent-linux-test bash /src/test/linux_test.sh
set -u
cd /tmp
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp >/dev/null 2>&1 &
for i in $(seq 50); do xdpyinfo -display :99 >/dev/null 2>&1 && break; sleep 0.1; done
export DISPLAY=:99

start_mock() {  # $1 port, rest env
  local port=$1; shift
  env "$@" MOCK_REPORT=/tmp/report_$port.json python3 /src/test/mock_api.py --port "$port" >/dev/null 2>&1 &
  for i in $(seq 50); do [ -s /tmp/report_$port.json ] && break; sleep 0.1; done
}

agent() {  # $1 port, rest env
  local port=$1; shift
  env "$@" SCREEN_AGENT_BASE_URL=http://127.0.0.1:$port python3 /src/linux/agent.py
}

report_ok() {  # $1 port $2 label  (check_report.py: done, no errors, enough checks passed)
  if python3 /src/test/check_report.py /tmp/report_$1.json > /tmp/check_$1.txt 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' /tmp/report_$1.json
    echo "PASS: $2 (check_report.py)"
  else
    cat /tmp/check_$1.txt; echo "FAIL: $2 (check_report.py)"; return 1
  fi
}

field() {  # $1 port $2 field -> prints the JSON value
  python3 -c 'import json,sys; print(json.dumps(json.load(open("/tmp/report_%s.json"%sys.argv[1])).get(sys.argv[2])))' "$1" "$2"
}

cursor_now() {
  python3 -c '
import ctypes
X=ctypes.CDLL("libX11.so.6"); X.XOpenDisplay.restype=ctypes.c_void_p; X.XOpenDisplay.argtypes=[ctypes.c_char_p]
d=X.XOpenDisplay(None); X.XDefaultRootWindow.argtypes=[ctypes.c_void_p]; X.XDefaultRootWindow.restype=ctypes.c_ulong
r=X.XDefaultRootWindow(d); a=ctypes.c_ulong(); b=ctypes.c_ulong(); x=ctypes.c_int(); y=ctypes.c_int(); wx=ctypes.c_int(); wy=ctypes.c_int(); m=ctypes.c_uint()
P=ctypes.POINTER
X.XQueryPointer.argtypes=[ctypes.c_void_p,ctypes.c_ulong,P(ctypes.c_ulong),P(ctypes.c_ulong),P(ctypes.c_int),P(ctypes.c_int),P(ctypes.c_int),P(ctypes.c_int),P(ctypes.c_uint)]
X.XQueryPointer(d,r,ctypes.byref(a),ctypes.byref(b),ctypes.byref(x),ctypes.byref(y),ctypes.byref(wx),ctypes.byref(wy),ctypes.byref(m)); print("%d,%d"%(x.value,y.value))'
}

echo "=== 1. full scripted session, real XTest input on Xvfb 1920x1080"
python3 /src/test/linux_keylog.py /tmp/keys.txt &
sleep 1
start_mock 8701
agent 8701 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test > /tmp/out1.txt 2>&1; echo "exit=$?"
cat /tmp/out1.txt
report_ok 8701 "scripted session" || FAIL=1
python3 -c 'import json,sys; s=json.load(open("/tmp/report_8701.json"))["image_sizes"]; print(s); sys.exit(0 if ["screenshot",1280,720] in s else 1)' \
  && pass "screenshot is 1280x720" || fail "screenshot size"
grep -q "cursor_position = 200,200" /tmp/out1.txt && pass "cursor_position after the drag reports 200,200" || fail "cursor position"
grep -q "Model claude-sonnet-5-5 " /tmp/out1.txt && pass "default model is claude-sonnet-5-5" || fail "default model"
[ "$(field 8701 calls)" = 5 ] && pass "session took 5 API calls" || fail "call count $(field 8701 calls)"
python3 -c 'import json,sys; s=json.load(open("/tmp/report_8701.json"))["image_sizes"]; sys.exit(0 if ["auto",1280,720] in s else 1)' \
  && pass "automatic screenshot attached, 1280x720" || fail "auto screenshot"
echo "cursor now: $(cursor_now)"
[ "$(cursor_now)" = 450,450 ] && pass "cursor ended at the step-2 click (300,300 -> 450,450 real px)" || fail "final cursor $(cursor_now)"
python3 -c 'print("typed:", repr(open("/tmp/keys.txt",encoding="utf-8").read()))'
python3 -c 'import sys; t=open("/tmp/keys.txt",encoding="utf-8").read(); sys.exit(0 if t=="héllo wörld\nline2a\n\nabc\n" else 1)' \
  && pass "keyboard received exactly: text, ctrl+a, Return x2, abc, Return" || fail "typed text"

echo "=== 2. 429 on first call -> retry-after honored"
start_mock 8702 MOCK_429_FIRST=1
agent 8702 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out2.txt 2>&1; echo "exit=$?"
grep "Rate limited" /tmp/out2.txt
report_ok 8702 "429 retry" || FAIL=1
python3 -c 'import json,sys; sys.exit(0 if json.load(open("/tmp/report_8702.json"))["saw_429"] else 1)' && pass "mock saw the 429" || fail "429 not exercised"

echo "=== 3. beta header rejected -> compat mode"
start_mock 8703 MOCK_REJECT_BETA=1
agent 8703 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out3.txt 2>&1; echo "exit=$?"
grep "compatibility" /tmp/out3.txt
report_ok 8703 "compat mode" || FAIL=1

echo "=== 4. first-run key flow (bad key, then good key)"
start_mock 8704
mkdir -p /tmp/h
printf 'sk-wrong\nsk-test-good\n' | agent 8704 HOME=/tmp/h SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out4.txt 2>&1; echo "exit=$?"
grep -E "rejected|saved" /tmp/out4.txt
grep -q "That key was rejected" /tmp/out4.txt && pass "bad key rejected" || fail "bad key message"
[ "$(stat -c %a /tmp/h/.screen-agent/key)" = 600 ] && pass "key saved mode 600" || fail "key mode $(stat -c %a /tmp/h/.screen-agent/key 2>&1)"
[ "$(cat /tmp/h/.screen-agent/key)" = sk-test-good ] && pass "saved key is the good key" || fail "saved key content"
echo "--- second run reuses saved key without prompting"
start_mock 8705
agent 8705 HOME=/tmp/h SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 < /dev/null > /tmp/out5.txt 2>&1; echo "exit=$?"
grep -q "Paste your API key" /tmp/out5.txt && fail "prompted again" || pass "no prompt on second run"
report_ok 8705 "saved key session" || FAIL=1

echo "=== 6. no X display"
env -u DISPLAY python3 /src/linux/agent.py; echo "exit=$?"
echo "=== 7. Wayland session"
XDG_SESSION_TYPE=wayland python3 /src/linux/agent.py; echo "exit=$?"
echo "=== 8. failsafe: cursor in top-left corner"
python3 - <<'EOF'
import ctypes
X=ctypes.CDLL("libX11.so.6"); T=ctypes.CDLL("libXtst.so.6")
X.XOpenDisplay.restype=ctypes.c_void_p; X.XOpenDisplay.argtypes=[ctypes.c_char_p]
d=X.XOpenDisplay(None)
T.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong]
T.XTestFakeMotionEvent(d,0,0,0,0); X.XFlush.argtypes=[ctypes.c_void_p]; X.XSync.argtypes=[ctypes.c_void_p,ctypes.c_int]; X.XSync(d,0)
EOF
start_mock 8706
agent 8706 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test > /tmp/out6.txt 2>&1; echo "exit=$?"
grep -q "Stopped (mouse in top-left corner)" /tmp/out6.txt && pass "failsafe stopped the task" || fail "failsafe"
python3 -c 'import json; r=json.load(open("/tmp/report_8706.json")); print("mock calls:", r["calls"], "done:", r["done"])'
# put the cursor back in the middle so later tests don't trip the failsafe
python3 -c '
import ctypes
X=ctypes.CDLL("libX11.so.6"); T=ctypes.CDLL("libXtst.so.6")
X.XOpenDisplay.restype=ctypes.c_void_p; X.XOpenDisplay.argtypes=[ctypes.c_char_p]; d=X.XOpenDisplay(None)
T.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong]
T.XTestFakeMotionEvent(d,0,960,540,0); X.XSync.argtypes=[ctypes.c_void_p,ctypes.c_int]; X.XSync(d,0)'

ws_is() {  # $1 port $2 expected workspace
  python3 -c 'import json,sys; r=json.load(open("/tmp/report_%s.json"%sys.argv[1])); print("report workspace:", r["workspace"]); sys.exit(0 if r["workspace"]==sys.argv[2] else 1)' "$1" "$2"
}

echo "=== 9. organization-wide key, workspace list -> pick 2"
start_mock 8707 MOCK_UNSCOPED=1
mkdir -p /tmp/h9
printf '2\n' | agent 8707 HOME=/tmp/h9 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out9.txt 2>&1; echo "exit=$?"
grep -E "several workspaces|^  [0-9]\)|Saved workspace|Using workspace" /tmp/out9.txt
grep -q "TESTARCHIVED" /tmp/out9.txt && fail "archived workspace was listed" || pass "archived workspace not listed"
report_ok 8707 "unscoped key, picked workspace 2" || FAIL=1
ws_is 8707 wrkspc_01TESTSECOND && pass "requests carried wrkspc_01TESTSECOND" || fail "workspace header"
[ "$(cat /tmp/h9/.screen-agent/workspace)" = wrkspc_01TESTSECOND ] && [ "$(stat -c %a /tmp/h9/.screen-agent/workspace)" = 600 ] \
  && pass "workspace saved, mode 600" || fail "workspace file"

echo "=== 10. organization-wide key, list forbidden -> paste (bad, then good)"
start_mock 8708 MOCK_UNSCOPED=nolist
mkdir -p /tmp/h10
printf 'wrkspc_01NOPE\nwrkspc_01TESTDEFAULT\n' | agent 8708 HOME=/tmp/h10 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out10.txt 2>&1; echo "exit=$?"
grep -E "across your organization|didn't work|Saved workspace" /tmp/out10.txt
grep -q "That workspace didn't work" /tmp/out10.txt && pass "bad workspace rejected" || fail "bad workspace message"
report_ok 8708 "unscoped key, pasted workspace" || FAIL=1
ws_is 8708 wrkspc_01TESTDEFAULT && pass "requests carried wrkspc_01TESTDEFAULT" || fail "workspace header"
[ "$(stat -c %a /tmp/h10/.screen-agent/workspace)" = 600 ] && pass "workspace saved, mode 600" || fail "workspace file mode"

echo "=== 11. ANTHROPIC_WORKSPACE_ID env -> no prompt"
start_mock 8709 MOCK_UNSCOPED=1
mkdir -p /tmp/h11
agent 8709 HOME=/tmp/h11 ANTHROPIC_API_KEY=sk-test-good ANTHROPIC_WORKSPACE_ID=wrkspc_01TESTSECOND SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 < /dev/null > /tmp/out11.txt 2>&1; echo "exit=$?"
grep -qE "Number:|Paste the workspace ID" /tmp/out11.txt && fail "prompted for workspace" || pass "no workspace prompt"
report_ok 8709 "env workspace" || FAIL=1
ws_is 8709 wrkspc_01TESTSECOND && pass "requests carried env workspace" || fail "workspace header"

echo "=== 12. first-run key prompt with an organization-wide key"
start_mock 8710 MOCK_UNSCOPED=1
mkdir -p /tmp/h12
printf 'sk-test-good\n1\n' | agent 8710 HOME=/tmp/h12 SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out12.txt 2>&1; echo "exit=$?"
grep -qE "rejected|Couldn't check" /tmp/out12.txt && fail "workspace-400 treated as a bad key" || pass "workspace-400 accepted as a good key"
report_ok 8710 "first-run org key" || FAIL=1
ws_is 8710 wrkspc_01TESTDEFAULT && pass "picked workspace 1" || fail "workspace header"

echo "=== 13. fast mode"
start_mock 8711
agent 8711 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_FAST=1 SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out13.txt 2>&1; echo "exit=$?"
report_ok 8711 "fast mode session" || FAIL=1
[ "$(field 8711 speed)" = '"fast"' ] && pass 'requests carried "speed": "fast"' || fail "speed $(field 8711 speed)"
start_mock 8712
agent 8712 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /dev/null 2>&1
[ "$(field 8712 speed)" = null ] && pass "no speed field when fast mode is off" || fail "speed sent without fast mode"

echo "=== 14. fast mode rejected by the API -> normal speed"
start_mock 8713 MOCK_REJECT_SPEED=1
agent 8713 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_FAST=1 SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 > /tmp/out14.txt 2>&1; echo "exit=$?"
grep "Fast mode" /tmp/out14.txt
grep -q "Fast mode isn't available for this key or model; continuing at normal speed." /tmp/out14.txt && pass "fallback message printed" || fail "fallback message"
report_ok 8713 "speed rejected, session still finishes" || FAIL=1
[ "$(field 8713 speed_rejected)" = true ] && pass "mock rejected speed" || fail "speed_rejected $(field 8713 speed_rejected)"

echo "=== 15. guide mode: looks, never sends input"
: > /tmp/keys.txt
BEFORE=$(cursor_now)
start_mock 8714
agent 8714 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_MODE=guide SCREEN_AGENT_TASK=test > /tmp/out15.txt 2>&1; echo "exit=$?"
cat /tmp/out15.txt
grep -q "Screen Agent (guide mode) — Claude can see the screen and tells you what to do. It can't click or type here." /tmp/out15.txt \
  && pass "guide banner" || fail "guide banner"
report_ok 8714 "guide session" || FAIL=1
[ "$(field 8714 guide)" = true ] && pass "mock saw the guide toolset (13 input members disabled)" || fail "guide flag"
[ ! -s /tmp/keys.txt ] && pass "key-log window received nothing" || fail "keys were sent in guide mode"
[ "$(cursor_now)" = "$BEFORE" ] && pass "cursor didn't move ($BEFORE)" || fail "cursor moved $BEFORE -> $(cursor_now)"

echo "=== 16. guide mode: disabled member called anyway; works without libXtst"
SCREEN_AGENT_MODE=guide python3 /src/test/linux_guide_check.py || FAIL=1
echo "--- control mode without libXtst gives a clear error"
python3 -c '
import sys; sys.path.insert(0, "/src/linux"); import agent as a
orig = a.load_lib; a.load_lib = lambda n, so: None if n == "Xtst" else orig(n, so); a.Screen()'; echo "exit=$?"

echo "=== 17. /fast and /help commands"
start_mock 8715
printf '/fast\n/fast\n/help\n/quit\n' | agent 8715 ANTHROPIC_API_KEY=sk-test-good > /tmp/out17.txt 2>&1; echo "exit=$?"
grep -E "Fast mode|/fast" /tmp/out17.txt
grep -q "Fast mode on (quicker replies, about twice the price)." /tmp/out17.txt && grep -q "Fast mode off." /tmp/out17.txt \
  && pass "/fast toggles on and off" || fail "/fast"
[ "$(grep -c '  /fast ' /tmp/out17.txt)" = 2 ] && pass "/fast is in the help text" || fail "/fast missing from help"
grep -q "needs SCREEN_AGENT_MODEL=claude-opus-5-5" /tmp/out17.txt && pass "/fast help names the model it needs" || fail "/fast help model note"

DEFWS=wrkspc_016got19sMpunUQcnrvjLxHf
echo "=== 18. built-in default workspace fits the key -> never asked"
start_mock 8716 MOCK_UNSCOPED=1 MOCK_EXTRA_WORKSPACE=$DEFWS
mkdir -p /tmp/h18
agent 8716 HOME=/tmp/h18 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 < /dev/null > /tmp/out18.txt 2>&1; echo "exit=$?"
grep -qE "Number:|Paste the workspace ID|several workspaces|Saved workspace" /tmp/out18.txt && fail "asked about a workspace" || pass "no workspace prompt"
report_ok 8716 "built-in default workspace" || FAIL=1
ws_is 8716 $DEFWS && pass "requests carried the built-in default" || fail "workspace header"
[ ! -e /tmp/h18/.screen-agent/workspace ] && pass "built-in default not written to the workspace file" || fail "workspace file was written"

echo "=== 19. key tied to its own workspace rejects the built-in default -> dropped"
start_mock 8717 MOCK_SCOPED_STRICT=1
mkdir -p /tmp/h19
agent 8717 HOME=/tmp/h19 ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK=test SCREEN_AGENT_DRY_RUN=1 < /dev/null > /tmp/out19.txt 2>&1; echo "exit=$?"
grep -qE "Number:|Paste the workspace ID|API error" /tmp/out19.txt && fail "prompt or error with a scoped key" || pass "no prompt, no error"
report_ok 8717 "scoped key, default dropped" || FAIL=1
[ "$(field 8717 workspace)" = null ] && pass "report workspace is null (no header sent)" || fail "workspace $(field 8717 workspace)"
[ ! -e /tmp/h19/.screen-agent/workspace ] && pass "no workspace file written" || fail "workspace file was written"

echo "=== 20. /key forgets the saved workspace; the built-in default applies again"
start_mock 8718 MOCK_UNSCOPED=1 MOCK_EXTRA_WORKSPACE=$DEFWS
mkdir -p /tmp/h20/.screen-agent
echo sk-test-good > /tmp/h20/.screen-agent/key; echo wrkspc_01TESTSECOND > /tmp/h20/.screen-agent/workspace
printf '/key\nsk-test-good\ngo\n/quit\n' | agent 8718 HOME=/tmp/h20 SCREEN_AGENT_DRY_RUN=1 > /tmp/out20.txt 2>&1; echo "exit=$?"
grep -qE "Number:|Paste the workspace ID" /tmp/out20.txt && fail "asked about a workspace after /key" || pass "no workspace prompt after /key"
report_ok 8718 "session after /key" || FAIL=1
ws_is 8718 $DEFWS && pass "after /key requests carried the built-in default" || fail "workspace header"
[ ! -e /tmp/h20/.screen-agent/workspace ] && pass "saved workspace forgotten, default not saved" || fail "workspace file still there"

echo
[ $FAIL = 0 ] && echo "ALL LINUX TESTS PASSED" || echo "SOME LINUX TESTS FAILED"
exit $FAIL
