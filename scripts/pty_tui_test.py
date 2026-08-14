#!/usr/bin/env python3
"""Interactive-TUI crash harness for copilot on Termux/bionic.

Why this exists: the 1.0.61+ pthread-attr-width segfault only reproduces on the
INTERACTIVE path, and reproducing it needs two things that are easy to miss:

  1. A real pty. Piped stdin does not crash - copilot skips the TUI renderer
     entirely, so `copilot -p ... | cat` looks perfectly healthy.
  2. Answers to the terminal capability queries. With a pty but a silent
     harness the TUI blocks forever waiting on DA/DSR/OSC replies and never
     reaches the crash site, so the run "passes" having rendered nothing.
     That false pass cost a whole debugging session once.

So: fork a pty, answer the queries, let it paint, then /exit. A pass requires
BOTH exit status 0 AND a plausible visible-character count - check `visible=`,
because a tiny number means the TUI never painted and the run proved nothing.

Reading RESULT=:
  EXIT 0 + visible in the hundreds+   pass
  SIGNAL 11                           the segfault this harness hunts for
  HANG                                the app ignored every /exit; OUR SIGKILL,
                                      not a crash. Judge it on `visible=`.

Lives in ~/.copilot-versions/ deliberately: $PREFIX/tmp gets wiped on restart,
and a missing harness fails silently as an empty RESULT line.

Usage:  python3 pty_tui_test.py [--nossl] [--noexit] [--wait SEC]
  --nossl   point the cert vars at a nonexistent file, defeating the wrapper's
            -z guard, to prove a missing trust store errors instead of crashing
  --noexit  do not send /exit; let it run to --wait then report
"""
import os, sys, pty, select, struct, termios, fcntl, time, re

WAIT = 35.0
NOSSL = "--nossl" in sys.argv
NOEXIT = "--noexit" in sys.argv
if "--wait" in sys.argv:
    WAIT = float(sys.argv[sys.argv.index("--wait") + 1])

# Override with COPILOT_CMD to launch something other than the wrapper - needed
# for unpatched-control runs, since the wrapper self-heals a pristine binary
# back to patched before it ever starts.
COPILOT = os.environ.get("COPILOT_CMD") or os.path.expanduser("~/.local/bin/copilot")
ROWS, COLS = 30, 100

def child():
    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    env.pop("CI", None)
    if NOSSL:
        # Defeat the wrapper's "only set if unset" guard with a path that
        # exists nowhere, so rustls really does load zero roots.
        for k in ("SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"):
            env[k] = "/nonexistent/no.pem"
    else:
        # Claude Code injects these; strip them so we test the wrapper's own
        # TLS setup rather than the parent shell's.
        for k in ("SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"):
            env.pop(k, None)
    os.execve(COPILOT, [COPILOT], env)

def reply(q):
    """Map a capability query to the response a real xterm would send."""
    if q == b"\x1b[>q":                      # XTVERSION
        return b"\x1bP>|xterm(370)\x1b\\"
    if q == b"\x1b[?2026$p":                 # synchronised update (DECRQM)
        return b"\x1b[?2026;2$y"
    if q == b"\x1b[?12$p":                   # cursor blink (DECRQM)
        return b"\x1b[?12;1$y"
    m = re.fullmatch(rb"\x1b\]1([01]);\?(?:\x1b\\|\x07)", q)
    if m:                                    # OSC 10/11 fg/bg colour
        c = b"0000/0000/0000" if m.group(1) == b"1" else b"ffff/ffff/ffff"
        return b"\x1b]1" + m.group(1) + b";rgb:" + c + b"\x1b\\"
    m = re.fullmatch(rb"\x1b\]4;(\d+);\?(?:\x1b\\|\x07)", q)
    if m:                                    # OSC 4 palette entry
        return b"\x1b]4;" + m.group(1) + b";rgb:8080/8080/8080\x1b\\"
    return None

QUERY = re.compile(
    rb"\x1b\[>q|\x1b\[\?\d+\$p|\x1b\]1[01];\?(?:\x1b\\|\x07)|\x1b\]4;\d+;\?(?:\x1b\\|\x07)")

def main():
    pid, fd = pty.fork()
    if pid == 0:
        child()
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    buf = b""
    pending = b""
    t0 = time.time()
    next_exit = WAIT
    exits_sent = 0
    status = None

    while True:
        el = time.time() - t0
        # Re-send /exit a few times rather than once. A keystroke that lands
        # while the app is still on "Loading: N plugins, M skills" gets
        # swallowed, and a single attempt then leaves a perfectly healthy run
        # to be SIGKILLed on timeout - which reads like a failure.
        if not NOEXIT and exits_sent < 4 and el > next_exit:
            try:
                os.write(fd, b"/exit\r")
            except OSError:
                pass
            exits_sent += 1
            next_exit = el + 8
        if el > WAIT + 45:
            break
        try:
            r, _, _ = select.select([fd], [], [], 0.4)
        except OSError:
            break
        if fd not in r:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf += data
        pending += data
        # Answer any complete query in the tail we have not answered yet.
        for m in QUERY.finditer(pending):
            resp = reply(m.group(0))
            if resp:
                try:
                    os.write(fd, resp)
                except OSError:
                    pass
        pending = pending[-64:]

    # Give it a reap window before concluding anything. On a crash the pty hits
    # EOF slightly BEFORE the child becomes waitable, so a single WNOHANG here
    # returns 0 and mislabels a real SIGSEGV as a hang.
    we_killed = False
    reaped, status = 0, 0
    reap_deadline = time.time() + 3.0
    while time.time() < reap_deadline:
        try:
            reaped, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            reaped, status = pid, 0
        if reaped != 0:
            break
        time.sleep(0.1)
    if reaped == 0:
        # Still alive: it ignored every /exit. That is a hang, not a crash -
        # label it so, because "SIGNAL 9" here is OUR kill and has nothing to do
        # with the pthread-width SIGSEGV this harness hunts for.
        #
        # Escalate gently. A SIGKILLed copilot leaves its session registered and
        # the WAL mid-flight, and the NEXT startup then stalls in "Session has
        # been disposed" / "NativeMcpHostHandle has been destroyed" cleanup and
        # renders nothing - which looks like a brand-new bug but is just our own
        # mess. SIGINT/SIGTERM let it unregister first.
        we_killed = True
        for sig, grace in ((2, 6.0), (15, 6.0), (9, 4.0)):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            deadline = time.time() + grace
            while time.time() < deadline:
                try:
                    reaped, status = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    reaped, status = pid, 0
                if reaped != 0:
                    break
                # Keep draining so it cannot block on a full pty buffer.
                try:
                    r, _, _ = select.select([fd], [], [], 0.3)
                    if fd in r:
                        os.read(fd, 65536)
                except OSError:
                    pass
            if reaped != 0:
                break

    el = time.time() - t0
    if we_killed:
        verdict = "HANG (harness SIGKILL, no crash)"
    elif os.WIFSIGNALED(status):
        verdict = "SIGNAL %d" % os.WTERMSIG(status)
    else:
        verdict = "EXIT %d" % os.WEXITSTATUS(status)

    # Strip escape sequences to count what a human would actually have seen.
    txt = buf.decode("utf8", "replace")
    visible = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", txt)
    visible = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", visible)
    visible = re.sub(r"\x1bP[^\x1b]*\x1b\\", "", visible)
    visible = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", visible)
    vis = len(visible.strip())

    print("RESULT=%s t=%.1fs bytes=%d visible=%d" % (verdict, el, len(buf), vis))
    if "--screen" in sys.argv:
        print("--- screen ---")
        print(visible[-3000:])

if __name__ == "__main__":
    main()
