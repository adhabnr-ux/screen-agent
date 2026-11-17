#!/usr/bin/env python3
"""Guide-mode checks the mock doesn't script. Run with SCREEN_AGENT_MODE=guide and DISPLAY set.

- Guide mode starts with libXtst absent (only screen capture is needed).
- A disabled input member called anyway gets the guide error and sends nothing.
- wait / cursor_position still work and get no automatic screenshot.
"""
import sys

sys.path.insert(0, "/src/linux")
import agent as a  # noqa: E402

orig = a.load_lib
a.load_lib = lambda n, so: None if n == "Xtst" else orig(n, so)  # as if libXtst were absent
sc = a.Screen()
ag = a.Agent(sc, "k")
before = sc.cursor()
res, stopped = ag.run_tools([
    {"id": "t1", "name": "left_click", "input": {"coordinate": [10, 10]}},
    {"id": "t2", "name": "screenshot", "input": {}}])
ok = (sc.T is None and res[0].get("is_error") is True and res[0]["content"] == a.GUIDE_MSG
      and res[1].get("is_error") is True and "Not executed" in res[1]["content"]
      and sc.cursor() == before and not stopped)
res2, _ = ag.run_tools([{"id": "t3", "name": "wait", "input": {"duration": 0.1}},
                        {"id": "t4", "name": "cursor_position", "input": {}},
                        {"id": "t5", "name": "zoom", "input": {"region": [0, 0, 200, 100]}}])
kinds = [[b["type"] for b in r["content"]] for r in res2]
ok2 = all(not r.get("is_error") for r in res2) and kinds == [["text"], ["text"], ["image"]]
print("error text:", res[0]["content"])
print(("PASS" if ok else "FAIL") + ": disabled member -> guide error, nothing sent, no libXtst needed")
print(("PASS" if ok2 else "FAIL") + ": wait/cursor_position/zoom work in guide mode, no screenshot attached %s" % kinds)
sys.exit(0 if ok and ok2 else 1)
