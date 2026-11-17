#!/usr/bin/env python3
"""Test helper: an X window that records the real pointer events it receives.

  DISPLAY=:99 python3 test/linux_pointerlog.py /tmp/pointer.txt

The window covers x 500..1700, y 300..900 of the screen. One line per event, root coordinates:
  P x y state button    ButtonPress
  M x y state           MotionNotify   (state & 256 = left button held)
  R x y state button    ButtonRelease
Truncate the file to start a new recording.
"""
import ctypes
import sys

out = sys.argv[1]


class XButtonEvent(ctypes.Structure):  # XMotionEvent has the same layout up to `state`
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("root", ctypes.c_ulong),
                ("subwindow", ctypes.c_ulong), ("time", ctypes.c_ulong),
                ("x", ctypes.c_int), ("y", ctypes.c_int), ("x_root", ctypes.c_int), ("y_root", ctypes.c_int),
                ("state", ctypes.c_uint), ("button", ctypes.c_uint), ("same_screen", ctypes.c_int)]


X = ctypes.CDLL("libX11.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultScreen.argtypes = [ctypes.c_void_p]
X.XRootWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
X.XRootWindow.restype = ctypes.c_ulong
X.XCreateSimpleWindow.argtypes = ([ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_int] * 2 +
                                  [ctypes.c_uint] * 3 + [ctypes.c_ulong] * 2)
X.XCreateSimpleWindow.restype = ctypes.c_ulong
X.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
X.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
X.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
X.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

d = X.XOpenDisplay(None)
root = X.XRootWindow(d, X.XDefaultScreen(d))
w = X.XCreateSimpleWindow(d, root, 500, 300, 1200, 600, 0, 0, 0x202020)
X.XSelectInput(d, w, (1 << 2) | (1 << 3) | (1 << 6))  # ButtonPress | ButtonRelease | PointerMotion
X.XMapRaised(d, w)
X.XSync(d, 0)
open(out, "w").close()
print("pointerlog ready", flush=True)
buf = ctypes.create_string_buffer(192)  # sizeof(XEvent)
ev = ctypes.cast(buf, ctypes.POINTER(XButtonEvent)).contents
while True:
    X.XNextEvent(d, buf)
    if ev.type == 4:
        line = "P %d %d %d %d" % (ev.x_root, ev.y_root, ev.state, ev.button)
    elif ev.type == 5:
        line = "R %d %d %d %d" % (ev.x_root, ev.y_root, ev.state, ev.button)
    elif ev.type == 6:
        line = "M %d %d %d" % (ev.x_root, ev.y_root, ev.state)
    else:
        continue
    with open(out, "a") as f:
        f.write(line + "\n")
