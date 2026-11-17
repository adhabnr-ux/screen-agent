#!/usr/bin/env python3
"""Checks for the pointer-motion rules in SPEC.md.

  linux_pointer_check.py unit
      pure check of agent.glide_path / straight_path (no display needed)
  linux_pointer_check.py events <log> <smooth|jump> SX SY EX EY TX TY
      check a linux_pointerlog.py recording of: left_click_drag (SX,SY)->(EX,EY), then
      mouse_move to (TX,TY). Coordinates are real screen pixels.
"""
import math
import sys

sys.path.insert(0, "/src/linux")
sys.path.insert(0, "linux")

FAILED = []


def check(ok, msg):
    print(("PASS: " if ok else "FAIL: ") + msg)
    if not ok:
        FAILED.append(msg)


def side_offsets(a, b, pts):
    """Signed distance of each point from the line a->b (positive = counter-clockwise normal side)."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    d = math.hypot(dx, dy)
    return [((p[0] - a[0]) * -dy + (p[1] - a[1]) * dx) / d for p in pts]


def progress(a, b, pts):
    dx, dy = b[0] - a[0], b[1] - a[1]
    d = math.hypot(dx, dy)
    return [((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / d for p in pts]


def unit():
    import agent as a
    W, H = 1920, 1080
    cases = [((100, 100), (900, 700)), ((960, 540), (630, 450)), ((1500, 200), (200, 900)),
             ((300, 500), (310, 506)), ((50, 1000), (1800, 60)), ((400, 400), (400, 700))]
    ok_last = ok_mono = ok_bow = ok_side = ok_n = ok_time = True
    worst = 0.0
    for A, B in cases:
        d = math.hypot(B[0] - A[0], B[1] - A[1])
        pts, dt = a.glide_path(A, B, W, H)
        T = min(0.6, max(0.15, 0.12 + d / 2500.0))
        n = max(8, int(round(T / 0.012)))
        ok_n &= len(pts) == n
        ok_time &= abs(dt * len(pts) - T) < 1e-9
        ok_last &= pts[-1] == (float(B[0]), float(B[1]))
        pr = progress(A, B, pts)
        ok_mono &= all(pr[i] <= pr[i + 1] + 1e-9 for i in range(len(pr) - 1)) and pr[0] > 0
        off = side_offsets(A, B, pts)
        worst = max(worst, max(abs(o) for o in off))
        ok_bow &= max(abs(o) for o in off) <= min(40.0, 0.08 * d) + 1e-9
        ok_side &= all(o >= -1e-9 for o in off) and max(off) > 0.5 * min(40.0, 0.08 * d)
    check(ok_last, "glide_path: last point is exactly B")
    check(ok_mono, "glide_path: progress along A->B never goes backwards")
    check(ok_bow, "glide_path: bow <= min(40, 0.08*d) (largest seen %.2f px)" % worst)
    check(ok_side, "glide_path: bows to one side only (counter-clockwise normal)")
    check(ok_n and ok_time, "glide_path: n = max(8, round(T/0.012)) steps, T = min(0.6, max(0.15, 0.12 + d/2500))")
    pts, dt = a.glide_path((10, 10), (11, 12), W, H)
    check(pts == [(11.0, 12.0)] and dt == 0.0, "glide_path: a move under 3 px is direct")
    pts, _ = a.glide_path((5, 2), (1900, 3), W, H)       # the bow would leave the top edge
    pts2, _ = a.glide_path((1915, 100), (1917, 1000), W, H)  # ... and the right edge
    inside = all(0 <= x <= W - 1 and 0 <= y <= H - 1 for x, y in pts + pts2)
    check(inside and pts[-1] == (1900.0, 3.0), "glide_path: every point is clamped to the screen")
    d = 300.0
    pts, dt = a.glide_path((630, 450), (930, 450), W, H, a.drag_duration(d))
    Td = min(0.9, max(0.3, 1.5 * min(0.6, max(0.15, 0.12 + d / 2500.0))))
    check(abs(a.drag_duration(d) - Td) < 1e-9 and len(pts) == max(8, int(round(Td / 0.012))),
          "drag: T_drag = min(0.9, max(0.3, 1.5*T)) -> %d steps for 300 px" % len(pts))
    sp = a.straight_path((0, 0), (130, 260), 12)
    even = all(abs(sp[i][0] - 10 * (i + 1)) < 1e-9 and abs(sp[i][1] - 20 * (i + 1)) < 1e-9 for i in range(12))
    check(len(sp) == 13 and even and sp[-1] == (130.0, 260.0), "straight_path: 12 evenly spaced points, then B")


def events(path, mode, S, E, T):
    ev = [l.split() for l in open(path) if l.strip()]
    ev = [(e[0], int(e[1]), int(e[2]), int(e[3])) + ((int(e[4]),) if len(e) > 4 else ()) for e in ev]
    kinds = "".join(e[0] for e in ev)
    print("events: %d total, sequence %s" % (len(ev), "".join(
        "%s%d " % (k, n) for k, n in runs(kinds))))
    pi = kinds.find("P")
    ri = kinds.find("R")
    check(kinds.count("P") == 1 and kinds.count("R") == 1 and 0 <= pi < ri, "exactly one ButtonPress, then one ButtonRelease")
    if not (0 <= pi < ri):
        return
    near = lambda e, p: abs(e[1] - p[0]) <= 2 and abs(e[2] - p[1]) <= 2  # noqa: E731
    check(near(ev[pi], S) and ev[pi][4] == 1, "ButtonPress (button 1) at the drag start %s, got (%d,%d)" % (S, ev[pi][1], ev[pi][2]))
    check(near(ev[ri], E) and ev[ri][4] == 1, "ButtonRelease at the drag end %s, got (%d,%d)" % (E, ev[ri][1], ev[ri][2]))
    drag = ev[pi + 1:ri]
    held = [e for e in drag if e[0] == "M" and e[3] & 0x100]
    need = 8 if mode == "smooth" else 12
    check(len(held) >= need and len(held) == len(drag),
          "drag: %d MotionNotify events between press and release, all with Button1 held (need >= %d)" % (len(held), need))
    check(len(set((e[1], e[2]) for e in held)) >= need, "drag: those moves visit >= %d distinct positions" % need)
    before = [e for e in ev[:pi] if e[0] == "M"]
    after = [e for e in ev[ri + 1:] if e[0] == "M"]
    check(all(not (e[3] & 0x100) for e in before + after), "no button held outside the drag")
    if mode == "smooth":
        check(len(before) >= 8, "glide to the drag start: %d motion events before the press" % len(before))
        pts = [(e[1], e[2]) for e in after]
        mid = set(pts[:-1])
        check(len(mid) >= 8, "mouse_move: %d distinct intermediate pointer positions (need >= 8)" % len(mid))
        check(bool(pts) and near(after[-1], T), "mouse_move ends at the target %s" % (T,))
        off = side_offsets(E, T, pts)
        big = [o for o in off if abs(o) >= 1]
        one_side = bool(big) and (all(o > 0 for o in big) or all(o < 0 for o in big))
        peak = max(abs(o) for o in off) if off else 0
        check(one_side and 5 <= peak <= 40.75,
              "mouse_move path bows to one side by %.1f px (<= 40 px, integer pixels)" % peak)
        pr = progress(E, T, pts)
        check(all(pr[i] <= pr[i + 1] + 1.5 for i in range(len(pr) - 1)), "mouse_move never doubles back")
    else:
        check(len(before) == 1 and near(before[0], S), "SMOOTH=0: the move to the drag start is one direct jump")
        check(len(after) == 1 and near(after[0], T), "SMOOTH=0: mouse_move is one direct jump to %s (%d motion event)" % (T, len(after)))


def runs(s):
    out = []
    for c in s:
        if out and out[-1][0] == c:
            out[-1][1] += 1
        else:
            out.append([c, 1])
    return out


if __name__ == "__main__":
    if sys.argv[1] == "unit":
        unit()
    else:
        v = [int(x) for x in sys.argv[4:10]]
        events(sys.argv[2], sys.argv[3], (v[0], v[1]), (v[2], v[3]), (v[4], v[5]))
    sys.exit(1 if FAILED else 0)
