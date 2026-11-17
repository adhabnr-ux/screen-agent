#!/usr/bin/env python3
"""Test helper: an X window that takes keyboard focus and logs typed characters to a file.

  DISPLAY=:99 python3 test/linux_keylog.py /tmp/keys.txt
"""
import ctypes
import sys

out = sys.argv[1]
X = ctypes.CDLL("libX11.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultScreen.argtypes = [ctypes.c_void_p]
X.XRootWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
X.XRootWindow.restype = ctypes.c_ulong
X.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_int] * 2 + [ctypes.c_uint] * 3 + [ctypes.c_ulong] * 2
X.XCreateSimpleWindow.restype = ctypes.c_ulong
X.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
X.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
X.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
X.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
X.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
X.XLookupString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_ulong), ctypes.c_void_p]

d = X.XOpenDisplay(None)
root = X.XRootWindow(d, X.XDefaultScreen(d))
w = X.XCreateSimpleWindow(d, root, 0, 0, 400, 300, 0, 0, 0)
X.XSelectInput(d, w, 1)  # KeyPressMask
X.XMapRaised(d, w)
X.XSync(d, 0)
X.XSetInputFocus(d, w, 2, 0)
X.XSync(d, 0)
open(out, "w").close()
print("keylog ready", flush=True)
ev = (ctypes.c_long * 24)()
buf = ctypes.create_string_buffer(32)
X.XRefreshKeyboardMapping.argtypes = [ctypes.c_void_p]
while True:
    X.XNextEvent(d, ev)
    etype = ctypes.cast(ev, ctypes.POINTER(ctypes.c_int))[0]
    if etype == 34:  # MappingNotify: refresh like every real X client does
        X.XRefreshKeyboardMapping(ev)
        continue
    if etype != 2:  # KeyPress
        continue
    ks = ctypes.c_ulong()
    X.XLookupString(ev, buf, 32, ctypes.byref(ks), None)
    k = ks.value
    if 0xFFE1 <= k <= 0xFFEE:  # modifier keys
        continue
    if k == 0xFF0D:
        ch = "\n"
    elif k < 0x100:
        ch = chr(k)
    elif k >= 0x1000000:
        ch = chr(k - 0x1000000)
    else:
        ch = "<%x>" % k
    with open(out, "a", encoding="utf-8") as f:
        f.write(ch)
