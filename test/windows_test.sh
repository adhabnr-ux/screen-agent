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
for f in windows/agent.ps1 windows/run.ps1 test/windows_stub.ps1; do
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
lint=$(echo "$code" | grep -E '\?\?|\?\.|&&|\|\||-AsHashtable|ForEach-Object -Parallel|Get-Error|-SkipCertificateCheck|ConvertFrom-Json -Depth')
tern=$(echo "$code" | grep -E '\) \? [^:]+ : ')
[ -z "$lint$tern" ] && pass "no PowerShell 7-only syntax" || { bad "PS7-only syntax"; echo "$lint$tern"; }
nonascii=$(python3 -c "import sys;[print(f,i+1) for f in sys.argv[1:] for i,l in enumerate(open(f,encoding='utf-8')) if any(ord(c)>127 for c in l)]" windows/agent.ps1 windows/run.ps1)
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
  mkdir -p "$T/appdata-$name"
  printf "%b" "${STDIN_TEXT:-}" > "$T/$name.stdin"
  tmo 120 env ${AGENT_ENV:-} APPDATA="$T/appdata-$name" SCREEN_AGENT_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-test-good \
  SCREEN_AGENT_TASK="Run the test batch" SCREEN_AGENT_TEST_STUB="$PWD/test/windows_stub.ps1" \
  SCREEN_AGENT_STUB_JPEG="$T/screen.jpg" SCREEN_AGENT_STUB_LOG="$stub" SCREEN_AGENT_STUB_CURSOR="${STUB_CURSOR:-500,500}" \
    "$PWSH" -NoProfile -NonInteractive -Command "$launch" <"$T/$name.stdin" >"$log" 2>&1
  local rc=$?
  kill $mpid 2>/dev/null; wait $mpid 2>/dev/null
  echo "---- $name (exit $rc) agent output:"; sed 's/^/  | /' "$log"
  echo "---- $name mock report:"; cat "$rep"; echo
}

check_report() {  # name, extra python condition
  python3 - "$T/$1.json" "$2" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r["done"] and not r["errors"] and eval(sys.argv[2] or "True")
sys.exit(0 if ok else 1)
EOF
}

run_case normal "" scriptblock
check_report normal "" && pass "full session via scriptblock launch (as run.ps1 does)" || bad "normal session"
grep -q "type héllo wörld\\\\nline2" "$T/normal.stub" && pass "unicode text reached the type layer intact" || bad "typed text mangled: $(grep '^type' "$T/normal.stub")"
grep -q "capture 0,0 1920x1080 -> 1280x720" "$T/normal.stub" && pass "screenshot scaled 1920x1080 -> 1280x720" || bad "screenshot scaling"
grep -q "capture 0,0 600x375 -> 1152x720" "$T/normal.stub" && pass "zoom region mapped to 600x375 screen px, fit to 1152x720" || bad "zoom mapping: $(grep 'capture' "$T/normal.stub")"
grep -q "move 315,240" "$T/normal.stub" && pass "click coordinate 210,160 -> 315,240 screen px" || bad "coordinate mapping"

run_case r429 "MOCK_429_FIRST=1" file
check_report r429 "r['saw_429']" && grep -q "Rate limited, retrying in 1s" "$T/r429.log" && pass "429 honoured retry-after and retried" || bad "429 retry"

run_case compat "MOCK_REJECT_BETA=1" file
check_report compat "r['compat']" && grep -q "compatibility mode" "$T/compat.log" && pass "compat mode after beta rejection" || bad "compat mode"

STUB_CURSOR="0,0" run_case failsafe "" file
if grep -q "Stopped (mouse in top-left corner)" "$T/failsafe.log" && ! grep -qE "^(move|mouse|key|type)" "$T/failsafe.stub"; then
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

# --- 6. launcher -------------------------------------------------------------------------------
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
