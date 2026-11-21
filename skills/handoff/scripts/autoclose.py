#!/usr/bin/env python3
"""Handoff wrap-up: closes the iTerm2 tab of your own Claude Code session by itself.

Path: session registry (~/.claude/sessions/*.json) -> pid -> tty -> the iTerm2 session
with the same tty. Without --run the script only checks that the tab can be found and
then restarts itself detached (own process group) with --run.

--run waits until the session is "idle" (the final message is done), then DELAY seconds.
It aborts WITHOUT closing if the registry entry changes meanwhile (the user types,
a background notification wakes the session) or if bg_check.sh still finds background
shells. Otherwise it closes only that tab (async_close with force).
Log: $HANDOFF_DIR/.autoclose-<sessionId>.log (default ~/.claude/handoffs)

usage: autoclose.py <SESSION_ID> [--delay S]
exit:  0 = close scheduled, 1 = no iTerm2 tab / module missing (close by hand), 2 = error
Needs the iterm2 Python module (pip install iterm2) and iTerm2's Python API enabled
(iTerm2 > Settings > General > Magic > Enable Python API).
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

try:
    import iterm2
except ImportError:
    print("MANUAL: Python module 'iterm2' is missing (pip install iterm2).")
    sys.exit(1)

SESS_DIR = os.path.expanduser("~/.claude/sessions")
LOG_DIR = os.path.expanduser(os.environ.get("HANDOFF_DIR", "~/.claude/handoffs"))
BG_CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bg_check.sh")
IDLE_TIMEOUT = 900  # s: longest wait for the final message to finish


def entry(sid):
    for f in glob.glob(os.path.join(SESS_DIR, "*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if d.get("sessionId") == sid and d.get("pid"):
            return d
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def tty_of(pid):
    out = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return "/dev/" + out if out and out != "??" else None


def log(sid, msg):
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    with open(os.path.join(LOG_DIR, f".autoclose-{sid}.log"), "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def stamp(e):
    return (e.get("status"), e.get("statusUpdatedAt"), e.get("updatedAt"))


async def find_session(conn, tty):
    app = await iterm2.async_get_app(conn)
    for w in app.terminal_windows:
        for t in w.tabs:
            for s in t.sessions:
                if await s.async_get_variable("tty") == tty:
                    return s
    return None


def wait_for_quiet(sid, delay):
    """None = ready to close, otherwise the reason to abort."""
    t0 = time.time()
    while time.time() - t0 < IDLE_TIMEOUT:
        e = entry(sid)
        if not e or not alive(e["pid"]):
            return "session already ended"
        if e.get("status") == "idle":
            before = stamp(e)
            time.sleep(delay)
            e2 = entry(sid)
            if not e2 or stamp(e2) != before:
                return "abort: session became active again"
            return None
        time.sleep(1)
    return f"abort: not idle after {IDLE_TIMEOUT} s"


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sid = args[0]
    if not re.fullmatch(r"[0-9A-Za-z-]{8,64}", sid):
        print("ERROR: unexpected session id.", file=sys.stderr)
        sys.exit(2)
    delay = 10
    if "--delay" in args:
        try:
            delay = max(3, min(120, int(args[args.index("--delay") + 1])))
        except (IndexError, ValueError):
            print("ERROR: --delay needs a number of seconds.", file=sys.stderr)
            sys.exit(2)
    run = "--run" in args

    e = entry(sid)
    if not e or not alive(e["pid"]):
        print("ERROR: session not in the registry or already ended.", file=sys.stderr)
        sys.exit(2)
    tty = tty_of(e["pid"])
    if not tty:
        print("MANUAL: session has no terminal (tty).")
        sys.exit(1)

    if not run:
        found = {}

        async def check(conn):
            s = await find_session(conn, tty)
            found["id"] = s.session_id if s else None

        try:
            iterm2.run_until_complete(check)
        except Exception as exc:  # API disabled, iTerm2 not running, ...
            print(f"MANUAL: iTerm2 Python API not reachable ({exc.__class__.__name__}).")
            sys.exit(1)
        if not found.get("id"):
            print(f"MANUAL: no iTerm2 tab with {tty} found.")
            sys.exit(1)
        subprocess.Popen([sys.executable, os.path.abspath(__file__), sid, "--delay", str(delay), "--run"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        log(sid, f"scheduled: iTerm2 {found['id'][:8]} ({tty}), {delay} s after idle")
        print(f"AUTO: tab {tty} closes {delay} s after the final message.")
        sys.exit(0)

    reason = wait_for_quiet(sid, delay)
    if reason:
        log(sid, reason)
        sys.exit(0)
    bg = subprocess.run([BG_CHECK, sid], capture_output=True, text=True)
    if bg.returncode != 0:
        log(sid, "abort: bg_check.sh exit %d: %s" % (bg.returncode, bg.stdout.strip()[:300]))
        sys.exit(0)

    result = {}

    async def close(conn):
        s = await find_session(conn, tty) if alive(e["pid"]) else None
        if s:
            await s.async_close(force=True)
        result["closed"] = bool(s)

    iterm2.run_until_complete(close)
    log(sid, "tab closed" if result.get("closed") else f"abort: tab {tty} is gone")


if __name__ == "__main__":
    main()
