#!/bin/bash
# Proves real typing and dragging on macOS: the agent types into TextEdit, saves, and drags the
# window by its title bar; then this script checks the saved file and the window's new position.
# Needs Accessibility for the calling process (GitHub's macOS runners grant it). Run from the repo root.
#   bash test/mac_real_input.sh
set -u
T="$(mktemp -d)"; DOC="$T/typed.txt"; : > "$DOC"
OUT="${REAL_INPUT_OUT:-$T}"; mkdir -p "$OUT"
shot() { /usr/sbin/screencapture -x "$OUT/$1.png" 2>/dev/null; }
front() { osascript -l JavaScript -e 'ObjC.import("Cocoa"); $.NSWorkspace.sharedWorkspace.frontmostApplication.localizedName.js'; }
fail() { echo "FAIL: $*"; shot fail; echo "frontmost app: $(front)"; echo "screenshots in $OUT"; echo "REAL_INPUT=failed"; exit 1; }

TRUSTED=$(osascript -l JavaScript -e 'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted()')
if [ "$TRUSTED" != "true" ]; then echo "This process has no Accessibility permission, so real input can't be tested here."; echo "REAL_INPUT=skipped"; exit 0; fi

bounds() { # prints: X Y W H of the frontmost TextEdit window on screen, or nothing
  osascript -l JavaScript -e '
    ObjC.import("Cocoa"); ObjC.import("CoreGraphics");
    var apps=$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.apple.TextEdit");
    var out="";
    if (apps.count>0) { var pid=apps.objectAtIndex(0).processIdentifier;
      var w=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1|16,0))).filter(function(x){return x.kCGWindowOwnerPID===pid && x.kCGWindowLayer===0 && x.kCGWindowBounds.Height>150;})[0];
      if (w) { var b=w.kCGWindowBounds; out=[b.X,b.Y,b.Width,b.Height].join(" "); } }
    out'
}
open -a TextEdit "$DOC"
for i in $(seq 40); do B="$(bounds)"; [ -n "$B" ] && break; sleep 0.5; done
[ -n "$B" ] || fail "TextEdit window never appeared"
sleep 1; B="$(bounds)"; read -r X Y W H <<< "$B"; echo "window before: $X,$Y ${W}x$H   frontmost app: $(front)"; shot before

SCREEN=$(osascript -l JavaScript -e 'ObjC.import("Cocoa"); var f=$.NSScreen.screens.objectAtIndex(0).frame; Math.round(f.size.width)+" "+Math.round(f.size.height)')
python3 - "$X" "$Y" "$W" "$H" $SCREEN "$T/script.json" <<'PY'
import sys, json
X, Y, W, H, SWd, SHt = map(float, sys.argv[1:7])
s = min(1, 1280 / SWd, 800 / SHt)
c = lambda x, y: [round(x * s), round(y * s)]
dx = 140 if X + W + 150 < SWd else -140
dy = 90 if Y + H + 100 < SHt else -90
script = [
    [{"name": "left_click", "input": {"coordinate": c(X + 70, Y + H - 60)}},
     {"name": "type", "input": {"text": "Hello world 123, caf\u00e9."}},
     {"name": "key", "input": {"text": "cmd+s"}}],
    [{"name": "left_click_drag", "input": {"start_coordinate": c(X + W / 2, Y + 12), "coordinate": c(X + W / 2 + dx, Y + 12 + dy)}}],
    [{"name": "screenshot", "input": {}}],
]
json.dump(script, open(sys.argv[7], "w"))
print("expected move: %d %d (scale %.4f)" % (round(round(dx * s) / s), round(round(dy * s) / s), s))
open(sys.argv[7] + ".expect", "w").write("%d %d" % (dx, dy))
PY
read -r DX DY < "$T/script.json.expect"

MOCK_SCRIPT="$T/script.json" MOCK_REPORT="$T/report.json" python3 test/mock_api.py --port 8799 >/dev/null 2>&1 &
MOCK=$!
for i in $(seq 40); do curl -s -o /dev/null http://127.0.0.1:8799/ && break; sleep 0.5; done
START=$(python3 -c 'import time;print(time.time())')
HOME_DIR="$T/home"; mkdir -p "$HOME_DIR/.screen-agent/tmp"
HOME="$HOME_DIR" SCREEN_AGENT_DRY_RUN= SCREEN_AGENT_MODE= SCREEN_AGENT_SKIP_PERMS=1 SCREEN_AGENT_BASE_URL=http://127.0.0.1:8799 \
  SCREEN_AGENT_KEY=sk-test-good SCREEN_AGENT_TASK=test osascript -l JavaScript mac/agent.js </dev/null
ELAPSED=$(python3 -c "import time;print(round(time.time()-$START,1))")
kill $MOCK 2>/dev/null; shot after
python3 test/check_report.py "$T/report.json" > "$T/check.txt"; RC=$?
tail -14 "$T/check.txt"; [ "$RC" = 0 ] || fail "mock report"
sleep 1
TYPED="$(python3 -c "import sys;print(open(sys.argv[1],encoding='utf-8',errors='replace').read().strip())" "$DOC")"
echo "saved file contains: '$TYPED'   (agent run took ${ELAPSED}s)"
# Real words only: TextEdit's autocorrect rewrites made-up words, as it would for a person typing.
[ "$TYPED" = "Hello world 123, café." ] || fail "typed text is wrong"
B2="$(bounds)"; read -r X2 Y2 W2 H2 <<< "$B2"; echo "window after:  $X2,$Y2"
python3 - "$X" "$Y" "$X2" "$Y2" "$DX" "$DY" <<'PY' || fail "the window did not move as dragged"
import sys
x, y, x2, y2, dx, dy = map(float, sys.argv[1:7])
mx, my = x2 - x, y2 - y
print("moved by %d,%d  expected %d,%d" % (mx, my, dx, dy))
sys.exit(0 if abs(mx - dx) <= 6 and abs(my - dy) <= 6 else 1)
PY
pkill -x TextEdit 2>/dev/null
echo "PASS: real typing and real dragging on macOS"; echo "REAL_INPUT=verified"
