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

report_ok() {  # $1 port $2 label
  python3 - "$1" "$2" <<'EOF'
import json, sys
r = json.load(open("/tmp/report_%s.json" % sys.argv[1]))
print(json.dumps(r))
ok = r["done"] and not r["errors"]
print(("PASS: " if ok else "FAIL: ") + sys.argv[2] + " mock report done=%s errors=%d passed=%d" % (r["done"], len(r["errors"]), r["passed"]))
sys.exit(0 if ok else 1)
EOF
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
grep -q "cursor_position = 200,200" /tmp/out1.txt && pass "cursor really moved to drag end (200,200)" || fail "cursor position"
python3 -c 'print("typed:", repr(open("/tmp/keys.txt",encoding="utf-8").read()))'
python3 -c 'import sys; t=open("/tmp/keys.txt",encoding="utf-8").read(); sys.exit(0 if t.startswith("héllo wörld\nline2") else 1)' \
  && pass "keyboard typed 'héllo wörld\\nline2' (incl. non-layout chars via spare keycode)" || fail "typed text"

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

echo
[ $FAIL = 0 ] && echo "ALL LINUX TESTS PASSED" || echo "SOME LINUX TESTS FAILED"
exit $FAIL
