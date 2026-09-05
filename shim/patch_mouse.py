#!/data/data/com.termux/files/usr/bin/python3
"""Make copilot's mouse tracking work in the Termux terminal.

Problem: with the server-side TIMELINE_TOUCHUP feature flag on, copilot enables
"any-event" mouse tracking, which is DECSET mode 1003 only:

    MOUSE_ANY: "\x1B[?1003h\x1B[?1006h"

Termux's terminal maps a fixed set of DECSET codes to internal bits and its
isMouseTrackingActive() is driven by the 1000/1002 bits. Mode 1003 alone does
not turn tracking on, and when tracking is off in the alternate screen Termux
converts finger swipes into DPAD_UP/DPAD_DOWN key presses instead of wheel
events. Those arrows reach copilot's prompt box, so a swipe cycles through
prompt history rather than scrolling the transcript.

Fix: also request mode 1002 (button-event tracking), which Termux does map.
1002 and 1003 are independent bits, so terminals that honour 1003 keep full
any-event reporting - this only adds a mode, it removes nothing. copilot's own
MOUSE_OFF already sends 1002l, so teardown stays symmetric and the terminal is
not left reporting mouse events after exit.

Idempotent: safe to re-run, and re-run by the wrapper after every npm upgrade.
Exit 0 = patched or already patched, 2 = target string not found (upstream
changed the constant; re-check before trusting mouse scrolling).
"""
import sys

ORIG    = r'MOUSE_ANY:"\x1B[?1003h\x1B[?1006h"'
PATCHED = r'MOUSE_ANY:"\x1B[?1002h\x1B[?1003h\x1B[?1006h"'

def main():
    if len(sys.argv) < 2:
        print("usage: patch_mouse.py <app.js> [--check]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, encoding="utf8", errors="surrogateescape") as fh:
        s = fh.read()

    if PATCHED in s:
        print("already patched (1002+1003 both requested)")
        return 0
    n = s.count(ORIG)
    if n != 1:
        print("target not found (%d occurrences of MOUSE_ANY constant) - upstream "
              "may have changed it; mouse scrolling in Termux is NOT patched" % n,
              file=sys.stderr)
        return 2
    if check:
        print("not patched (would patch 1 occurrence)")
        return 1
    with open(path, "w", encoding="utf8", errors="surrogateescape") as fh:
        fh.write(s.replace(ORIG, PATCHED))
    print("patched: any-event mouse now requests 1002 as well as 1003")
    return 0

sys.exit(main())
