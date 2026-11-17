#!/usr/bin/env bash
# Tests windows/agent.ps1 and windows/run.ps1 with PowerShell 7 (any OS) against test/mock_api.py.
# The Win32 layer is replaced by test/windows_stub.ps1, so this checks the protocol, not real input.
#   PWSH=/path/to/pwsh test/windows_test.sh
set -u
cd "$(dirname "$0")/.."
PWSH="${PWSH:-pwsh}"
T="$(mktemp -d)"
fail=0
pass() { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
tmo() { if command -v timeout >/dev/null; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }

# --- 1x1 JPEG at 1280x720 for the stub screen -------------------------------------------------
python3 - "$T/screen.png" <<'EOF'
import struct, sys, zlib
w, h = 1280, 720
line = b"\x00" + bytes([(x * 7) % 256 for x in range(w * 3)])
rows = line * h
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
EOF
if command -v sips >/dev/null; then sips -s format jpeg "$T/screen.png" --out "$T/screen.jpg" >/dev/null
fi
[ -s "$T/screen.jpg" ] && pass "stub JPEG generated" || bad "stub JPEG"

# --- 2. parse check ---------------------------------------------------------------------------
PSFILES="windows/agent.ps1 windows/run.ps1 test/windows_stub.ps1 test/windows_real_input.ps1 test/windows_real_input_helper.ps1 test/windows_json_test.ps1 test/windows_motion_test.ps1"
for f in $PSFILES; do
  out=$("$PWSH" -NoProfile -Command "\$e=\$null; \$t=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$PWD/$f',[ref]\$t,[ref]\$e); if(\$e){\$e|%{ \$_.Extent.StartLineNumber.ToString() + ': ' + \$_.Message }; exit 1}")
  [ $? -eq 0 ] && pass "parse $f" || { bad "parse $f"; echo "$out"; }
done

# --- 3. Windows PowerShell 5.1 syntax lint (5.1 can't run here) -------------------------------
psonly() { python3 - "$@" <<'PY'
import sys
for f in sys.argv[1:]:
    inside = False
    for n, l in enumerate(open(f, encoding="utf-8"), 1):
        if l.rstrip().endswith("@'"): inside = True; continue
        if l.startswith("'@"): inside = False; continue
        if not inside and not l.lstrip().startswith("#"): print(f"{f}:{n}:{l}", end="")
PY
}
code=$(psonly windows/agent.ps1 windows/run.ps1)
testcode=$(psonly test/windows_real_input.ps1 test/windows_real_input_helper.ps1)
lint=$(echo "$code" | grep -E '\?\?|\?\.|&&|\|\||-AsHashtable|ForEach-Object -Parallel|Get-Error|-SkipCertificateCheck|ConvertFrom-Json -Depth')
tern=$(echo "$code" | grep -E '\) \? [^:]+ : ')
[ -z "$lint$tern" ] && pass "no PowerShell 7-only syntax" || { bad "PS7-only syntax"; echo "$lint$tern"; }
[ "$(grep -c 'Add-Type -TypeDefinition' windows/agent.ps1)" = 1 ] && ! grep -qE 'Reflection\.Emit|DefinePInvokeMethod|DllImport' <(echo "$code") \
  && pass "exactly one C# compile site; no other route to native input" || bad "extra compile/native route"
out=$("$PWSH" -NoProfile -File test/windows_json_test.ps1 "$PWD/windows/agent.ps1" 2>&1)
[ $? -eq 0 ] && pass "pure-PowerShell JSON extractor ($(echo "$out" | grep -c '^ok') checks)" || { bad "JSON extractor"; echo "$out"; }
out=$("$PWSH" -NoProfile -File test/windows_motion_test.ps1 "$PWD/windows/agent.ps1" 2>&1)
if [ $? -eq 0 ]; then pass "pointer path + typing pace unit tests ($(echo "$out" | grep -c '^ok') checks)"; echo "$out" | grep -E "600 px move|15 characters at 110|stop corner" | sed 's/^/        /'
else bad "pointer path / typing pace unit tests"; echo "$out" | grep -v '^ok'; fi
tlint=$(echo "$testcode" | grep -E '\?\?|\?\.|&&|\|\||-AsHashtable|ForEach-Object -Parallel|\) \? [^:]+ : ')
[ -z "$tlint" ] && pass "real-input test scripts: no PowerShell 7-only syntax" || { bad "PS7-only syntax in real-input test"; echo "$tlint"; }
nonascii=$(python3 -c "import sys;[print(f,i+1) for f in sys.argv[1:] for i,l in enumerate(open(f,encoding='utf-8')) if any(ord(c)>127 for c in l)]" $PSFILES)
[ -z "$nonascii" ] && pass "scripts are ASCII" || { bad "non-ASCII characters"; echo "$nonascii"; }

# --- 4. protocol runs against the mock --------------------------------------------------------
run_case() {  # name, mock-env, launch-mode (file|scriptblock); stdin text in $STDIN_TEXT, extra env in $AGENT_ENV
  local name="$1" menv="$2" mode="$3" port=$((20000 + RANDOM % 20000))
  local rep="$T/$name.json" log="$T/$name.log" stub="$T/$name.stub"
  env $menv MOCK_REPORT="$rep" python3 test/mock_api.py --port $port >/dev/null 2>&1 &
  local mpid=$!
  for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1 && break; sleep 0.1; done
  local launch="& '$PWD/windows/agent.ps1'"
  [ "$mode" = scriptblock ] && launch="& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$PWD/windows/agent.ps1')))"
  local wpmenv="SCREEN_AGENT_WPM=0"   # typing pace off for speed, except where a test asks for the default
  [ "${TEST_WPM:-}" = default ] && wpmenv="SCREEN_AGENT_UNUSED=1"
  mkdir -p "$T/appdata-$name"
  printf "%b" "${STDIN_TEXT:-}" > "$T/$name.stdin"
  tmo 120 env ${AGENT_ENV:-} APPDATA="$T/appdata-$name" SCREEN_AGENT_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-test-good \
  SCREEN_AGENT_TASK="Run the test batch" SCREEN_AGENT_TEST_STUB="$PWD/test/windows_stub.ps1" \
  SCREEN_AGENT_STUB_JPEG="$T/screen.jpg" SCREEN_AGENT_STUB_LOG="$stub" SCREEN_AGENT_STUB_CURSOR="${STUB_CURSOR:-500,500}" $wpmenv \
    "$PWSH" -NoProfile -NonInteractive -Command "$launch; if ('ScreenAgentWin2' -as [type]) { 'INPUT-LAYER-COMPILED' } else { 'INPUT-LAYER-NOT-COMPILED' }" <"$T/$name.stdin" >"$log" 2>&1
  local rc=$?
  kill $mpid 2>/dev/null; wait $mpid 2>/dev/null
  echo "---- $name (exit $rc) agent output:"; sed 's/^/  | /' "$log"
  echo "---- $name mock report:"; cat "$rep"; echo
}

check_report() {  # name, extra python condition
  python3 - "$T/$1.json" "$2" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r["done"] and not r["errors"] and r.get("passed", 0) >= (5 if r.get("guide") else 100) and eval(sys.argv[2] or "True")
sys.exit(0 if ok else 1)
EOF
}

TEST_WPM=default run_case normal "" scriptblock
check_report normal "r['calls']==5 and not r['guide'] and r['speed'] is None" && grep -q "Model claude-sonnet-5-5 " "$T/normal.log" && grep -qx "INPUT-LAYER-COMPILED" "$T/normal.log" && pass "full 5-call session via scriptblock launch (as run.ps1 does), default model claude-sonnet-5-5" || bad "normal session"
check_report normal "['auto',1280,720] in r['image_sizes']" && [ "$(grep -c 'capture 0,0 1920x1080 -> 1280x720' "$T/normal.stub")" = 3 ] \
  && pass "auto-screenshot attached to the clean batch only (3 full captures: 2 asked + 1 automatic)" || bad "auto-screenshot: $(grep -c 'capture 0,0 1920x1080' "$T/normal.stub") full captures"
typed() { python3 -c "
import sys
out=''
for l in open(sys.argv[1], encoding='utf-8'):
    if l.startswith('char '): out += ''.join(chr(int(h,16)) for h in l.split()[1:])
print(ascii(out))" "$1"; }
[ "$(typed "$T/normal.stub")" = "'h\xe9llo w\xf6rld\nline2abc'" ] && pass "unicode text reached the type layer intact, one character at a time ($(grep -c '^char' "$T/normal.stub") characters)" || bad "typed text mangled: $(typed "$T/normal.stub")"
# glide: the stub pointer sits at 500,500; mouse_move to 300,225 is 340 px -> T=0.256 s -> 21 steps ending exactly on target
python3 - "$T/normal.stub" <<'PY' && pass "glide: 21 eased steps to the first target; drag sent as 26 held moves between press and release" || bad "glide/drag sequence in stub log"
import sys
L = [l.strip() for l in open(sys.argv[1], encoding="utf-8")]
i = L.index("move 300,225")
first = [l for l in L[:i + 1] if l.startswith("move ")]
ok = len(first) == 21 and len(set(first)) >= 15
d0 = L.index("move 150,150")                      # drag start (100,100 in screenshot space)
up = L.index("mouse 0x4 0", d0 + 1)
held = L[d0 + 2:up]
# 150,150 -> 300,300 is 212 px: T=0.2049 -> drag T=0.3073 -> 26 steps
ok = ok and L[d0 + 1] == "mouse 0x2 0" and all(h.startswith("dragmove ") for h in held) and len(held) == 26 and held[-1] == "dragmove 300,300"
print("        first glide steps:", len(first), "| held drag moves:", len(held), "| last:", held[-1] if held else None)
sys.exit(0 if ok else 1)
PY
grep -q "capture 0,0 1920x1080 -> 1280x720" "$T/normal.stub" && pass "screenshot scaled 1920x1080 -> 1280x720" || bad "screenshot scaling"
grep -q "capture 0,0 600x375 -> 1152x720" "$T/normal.stub" && pass "zoom region mapped to 600x375 screen px, fit to 1152x720" || bad "zoom mapping: $(grep 'capture' "$T/normal.stub")"
grep -q "move 315,240" "$T/normal.stub" && pass "click coordinate 210,160 -> 315,240 screen px" || bad "coordinate mapping"

run_case r429 "MOCK_429_FIRST=1" file
check_report r429 "r['saw_429']" && grep -q "Rate limited, retrying in 1s" "$T/r429.log" && pass "429 honoured retry-after and retried" || bad "429 retry"

run_case compat "MOCK_REJECT_BETA=1" file
check_report compat "r['compat']" && grep -q "compatibility mode" "$T/compat.log" && pass "compat mode after beta rejection" || bad "compat mode"

STUB_CURSOR="0,0" run_case failsafe "" file
if grep -q "Stopped (mouse in top-left corner)" "$T/failsafe.log" && ! grep -qE "^(move|dragmove|mouse|key|char)" "$T/failsafe.stub"; then
  pass "failsafe: cursor in corner stops before any input"; else bad "failsafe"; fi

# --- 5. organization-wide keys (anthropic-workspace-id) -----------------------------------------
STDIN_TEXT="2\n" run_case ws_pick "MOCK_UNSCOPED=1" file
check_report ws_pick "r['workspace']=='wrkspc_01TESTSECOND'" && grep -q "1) Default Workspace  (wrkspc_01TESTDEFAULT)" "$T/ws_pick.log" \
  && ! grep -q "Old" "$T/ws_pick.log" && grep -q "Saved workspace wrkspc_01TESTSECOND." "$T/ws_pick.log" \
  && grep -qx "wrkspc_01TESTSECOND" "$T/appdata-ws_pick/screen-agent/workspace.txt" \
  && pass "workspace list: picked #2, archived hidden, saved to workspace.txt, session done" || bad "workspace pick"

STDIN_TEXT="wrkspc_01NOPE\nwrkspc_01TESTDEFAULT\n" run_case ws_paste "MOCK_UNSCOPED=nolist" file
check_report ws_paste "r['workspace']=='wrkspc_01TESTDEFAULT'" && grep -q "That workspace didn't work: Workspace wrkspc_01NOPE not found." "$T/ws_paste.log" \
  && grep -q "Saved workspace wrkspc_01TESTDEFAULT." "$T/ws_paste.log" \
  && pass "workspace paste: bad ID rejected, good ID verified, session done" || bad "workspace paste"

AGENT_ENV="ANTHROPIC_WORKSPACE_ID=wrkspc_01TESTSECOND" run_case ws_env "MOCK_UNSCOPED=1" file
check_report ws_env "r['workspace']=='wrkspc_01TESTSECOND'" && ! grep -qE "Number:|Paste the workspace|several workspaces" "$T/ws_env.log" \
  && pass "ANTHROPIC_WORKSPACE_ID: header sent, no prompt" || bad "workspace env override"

DEFWS=wrkspc_016got19sMpunUQcnrvjLxHf
run_case ws_default "MOCK_UNSCOPED=1 MOCK_EXTRA_WORKSPACE=$DEFWS" file
check_report ws_default "r['workspace']=='$DEFWS'" && ! grep -qE "Number:|Paste the workspace|several workspaces|workspace" "$T/ws_default.log" \
  && [ ! -e "$T/appdata-ws_default/screen-agent/workspace.txt" ] \
  && pass "built-in default workspace: used without a prompt, never written to workspace.txt" || bad "built-in default workspace"

run_case ws_strict "MOCK_SCOPED_STRICT=1" file
check_report ws_strict "r['workspace'] is None" && ! grep -qi "workspace" "$T/ws_strict.log" \
  && [ ! -e "$T/appdata-ws_strict/screen-agent/workspace.txt" ] \
  && pass "key tied to one workspace: built-in default dropped quietly, no header sent" || bad "scoped-strict key"

# mid-session: startup check passes, /v1/messages rejects the built-in default -> drop it, retry once
port=$((20000 + RANDOM % 20000)); MOCK_REPORT="$T/wsmid.json" python3 test/windows_ws_midsession_mock.py $port >/dev/null 2>&1 & mpid=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1 && break; sleep 0.1; done
mkdir -p "$T/appdata-wsmid"
tmo 120 env APPDATA="$T/appdata-wsmid" SCREEN_AGENT_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-test-good SCREEN_AGENT_TASK="hello" \
  SCREEN_AGENT_TEST_STUB="$PWD/test/windows_stub.ps1" SCREEN_AGENT_STUB_JPEG="$T/screen.jpg" \
  "$PWSH" -NoProfile -NonInteractive -File windows/agent.ps1 </dev/null >"$T/wsmid.log" 2>&1
kill $mpid 2>/dev/null; wait $mpid 2>/dev/null
echo "---- wsmid agent output:"; sed 's/^/  | /' "$T/wsmid.log"; echo "---- wsmid mock report:"; cat "$T/wsmid.json"; echo
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r['posts']==['$DEFWS', None] else 1)" "$T/wsmid.json" \
  && grep -q "Nothing to do." "$T/wsmid.log" && ! grep -qi "error\|workspace" "$T/wsmid.log" && [ ! -e "$T/appdata-wsmid/screen-agent/workspace.txt" ] \
  && pass "mid-session: built-in default rejected by /v1/messages -> dropped, retried once with no header" || bad "mid-session default drop"

# --- 6. fast mode and guide mode ----------------------------------------------------------------
AGENT_ENV="SCREEN_AGENT_FAST=1" run_case fast "" file
check_report fast "r['speed']=='fast' and not r['speed_rejected']" && pass "SCREEN_AGENT_FAST=1 sends speed: fast" || bad "fast mode"

AGENT_ENV="SCREEN_AGENT_FAST=1" run_case fast_rej "MOCK_REJECT_SPEED=1" file
check_report fast_rej "r['speed_rejected'] and r['speed'] is None" && grep -q "Fast mode isn't available for this key or model; continuing at normal speed." "$T/fast_rej.log" \
  && pass "rejected speed: fast mode turned off, request retried, session done" || bad "fast mode fallback"

AGENT_ENV="SCREEN_AGENT_MODE=guide" run_case guide "" file
check_report guide "r['guide'] and r['calls']==2" && grep -q "Screen Agent (guide mode)" "$T/guide.log" \
  && ! grep -qE "^(move|dragmove|mouse|key|char)" "$T/guide.stub" && [ "$(grep -c '^capture' "$T/guide.stub")" = 1 ] \
  && grep -qx "INPUT-LAYER-NOT-COMPILED" "$T/guide.log" \
  && pass "guide mode: 13 input members disabled, guide prompt + banner, zero input events, no auto-screenshot, no C# compiled" || bad "guide mode"

AGENT_ENV="SCREEN_AGENT_TEST_NO_COMPILE=1" run_case nocompile "" file
check_report nocompile "r['guide'] and r['calls']==2" \
  && grep -qF "This computer's policy doesn't let Screen Agent control the mouse and keyboard. Continuing in guide mode: Claude sees the screen and tells you what to click." "$T/nocompile.log" \
  && grep -q "Screen Agent (guide mode)" "$T/nocompile.log" && grep -qx "INPUT-LAYER-NOT-COMPILED" "$T/nocompile.log" \
  && ! grep -qE "^(move|dragmove|mouse|key|char)" "$T/nocompile.stub" \
  && pass "compile blocked: policy message, falls back to guide mode, zero input events" || bad "compile-blocked fallback"

AGENT_ENV="SCREEN_AGENT_SMOOTH=0" run_case nosmooth "" file
check_report nosmooth "" && [ "$(grep -c '^move' "$T/nosmooth.stub")" = 8 ] && [ "$(grep -c '^dragmove' "$T/nosmooth.stub")" = 12 ] \
  && pass "SCREEN_AGENT_SMOOTH=0: 8 direct moves, drag still sends 12 intermediate moves" || bad "SMOOTH=0: $(grep -c '^move' "$T/nosmooth.stub") moves, $(grep -c '^dragmove' "$T/nosmooth.stub") drag moves"

AGENT_ENV="SCREEN_AGENT_DRY_RUN=1" run_case dry "" file
check_report dry "['auto',1280,720] in r['image_sizes']" && ! grep -qE "^(move|dragmove|mouse|key|char)" "$T/dry.stub" \
  && pass "dry run: zero input events, auto-screenshot still attached" || bad "dry run"

# --- 7. launcher -------------------------------------------------------------------------------
cmd=$(SCREEN_AGENT_LAUNCH_PRINT=1 SCREEN_AGENT_REPO_RAW="http://127.0.0.1:1/x" "$PWSH" -NoProfile -File windows/run.ps1)
echo "$cmd" | grep -q '"' && bad "launcher command contains a double quote" || pass "launcher command has no double quotes"
out=$("$PWSH" -NoProfile -Command "\$e=\$null;\$t=\$null;[void][System.Management.Automation.Language.Parser]::ParseInput(@'
$cmd
'@,[ref]\$t,[ref]\$e); if(\$e){\$e|%{\$_.Message}; exit 1}")
[ $? -eq 0 ] && pass "new-window command parses" || { bad "new-window command"; echo "$out"; }

# fallback path: no powershell.exe/pwsh.exe on this OS -> runs agent in this window, fetched over HTTP
port=$((20000 + RANDOM % 20000)); python3 -m http.server $port --bind 127.0.0.1 >/dev/null 2>&1 & spid=$!
mport=$((port + 1)); MOCK_REPORT="$T/launch.json" python3 test/mock_api.py --port $mport >/dev/null 2>&1 & mpid=$!
sleep 1
SCREEN_AGENT_REPO_RAW="http://127.0.0.1:$port" SCREEN_AGENT_BASE_URL="http://127.0.0.1:$mport" ANTHROPIC_API_KEY=sk-test-good \
SCREEN_AGENT_TASK="Run the test batch" SCREEN_AGENT_TEST_STUB="$PWD/test/windows_stub.ps1" SCREEN_AGENT_STUB_JPEG="$T/screen.jpg" \
  tmo 120 "$PWSH" -NoProfile -NonInteractive -Command "Invoke-RestMethod -UseBasicParsing http://127.0.0.1:$port/windows/run.ps1 | Invoke-Expression" >"$T/launch.log" 2>&1
kill $spid $mpid 2>/dev/null; wait 2>/dev/null
check_report launch "" && grep -q "starting Screen Agent here" "$T/launch.log" && pass "irm | iex launcher fallback runs the agent end to end" || { bad "launcher fallback"; cat "$T/launch.log"; }

echo
[ $fail -eq 0 ] && echo "ALL WINDOWS TESTS PASSED" || echo "SOME WINDOWS TESTS FAILED"
rm -rf "$T"
exit $fail
