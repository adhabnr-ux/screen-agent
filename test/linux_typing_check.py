#!/usr/bin/env python3
"""Typing-speed checks (SPEC.md "Typing speed").

  linux_typing_check.py speed <times_default> <times_wpm0> <n_chars>
      key-press timestamps (ms, one per line) recorded by linux_keylog.py for the same text typed
      at the default speed and with SCREEN_AGENT_WPM=0
  linux_typing_check.py stop <keys_file> <n_chars>
      run with SCREEN_AGENT_WPM set high and something moving the pointer to 0,0 a moment later:
      types a long text through the agent and checks that typing stops early with the Stopped error
"""
import sys

sys.path.insert(0, "/src/linux")
FAILED = []


def check(ok, msg):
    print(("PASS: " if ok else "FAIL: ") + msg)
    if not ok:
        FAILED.append(msg)


def speed(default_file, fast_file, n):
    d = [int(x) for x in open(default_file).read().split()]
    f = [int(x) for x in open(fast_file).read().split()]
    check(len(d) == n and len(f) == n, "every character arrived as one key press (%d and %d of %d)" % (len(d), len(f), n))
    if len(d) < 2 or len(f) < 2:
        return
    gaps = [(d[i + 1] - d[i]) / 1000.0 for i in range(len(d) - 1)]
    avg = sum(gaps) / len(gaps)
    target = 60.0 / (110 * 5)
    print("default: %d gaps, average %.4f s (target %.4f s), shortest %.3f s, longest %.3f s"
          % (len(gaps), avg, target, min(gaps), max(gaps)))
    check(abs(avg - target) <= 0.25 * target, "default speed: average gap %.4f s is within 25%% of %.4f s (110 wpm)" % (avg, target))
    check(max(gaps) <= 2 * target and min(gaps) >= 0.3 * target, "default speed is steady (no gap over twice or under 0.3x the target)")
    total_d = (d[-1] - d[0]) / 1000.0
    total_f = (f[-1] - f[0]) / 1000.0
    print("total time for the same text: default %.2f s, SCREEN_AGENT_WPM=0 %.2f s" % (total_d, total_f))
    check(total_f < 0.5 * total_d, "WPM=0 is well under half the default time (%.0f%% of it)" % (100.0 * total_f / total_d))


def stop(keys_file, n):
    import agent as a
    sc = a.Screen()
    ag = a.Agent(sc, "k")
    text = ("abcdefghijklmnopqrstuvwxy" * (n // 25 + 1))[:n]
    res, stopped = ag.run_tools([{"id": "t1", "name": "type", "input": {"text": text}},
                                 {"id": "t2", "name": "screenshot", "input": {}}])
    import time
    time.sleep(0.3)
    typed = open(keys_file, encoding="utf-8").read()
    print("typed %d of %d characters before stopping; pointer at %s" % (len(typed), n, sc.cursor()))
    check(stopped, "run_tools reports the task as stopped")
    check(0 < len(typed) < n and len(typed) % 25 == 0 and text.startswith(typed),
          "typing stopped early, at a 25-character check (%d characters)" % len(typed))
    check(res[0].get("is_error") is True and res[0]["content"] == a.STOP_MSG, "the type result is the Stopped error: %r" % res[0]["content"])
    check(res[1].get("is_error") is True and res[1]["content"] == a.STOP_MSG, "the later action in the turn also gets the Stopped error")
    check(not sc.held_keys, "no key left held down")


if __name__ == "__main__":
    if sys.argv[1] == "speed":
        speed(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        stop(sys.argv[2], int(sys.argv[3]))
    sys.exit(1 if FAILED else 0)
