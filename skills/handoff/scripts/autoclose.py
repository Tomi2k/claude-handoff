#!/usr/bin/env python3
"""Handoff wrap-up: closes the iTerm2 tab of your own agent session by itself.

Works for Claude Code, Codex, agy and Grok. The script finds its own CLI by walking up
the process tree (phself.py): CLI pid -> tty -> the iTerm2 session with the same tty.
Without --run it only checks that the tab can be found and then restarts itself
detached (own process group) with --run.

--run waits until the session is idle (the final message is done):
  claude  the session registry says "idle" (~/.claude/sessions/*.json)
  others  the screen stops changing for QUIET seconds and shows no busy marker
Then it waits DELAY seconds more. It aborts WITHOUT closing if the text in the input box
changes meanwhile (the user types, even without sending; without a visible input box:
any change of the screen text except digits), if the session becomes active again
(claude: registry entry changes; others: a busy marker appears), or if bg_check.sh
still finds background shells. Otherwise it closes only that tab (async_close with force).
Log: $HANDOFF_DIR/.autoclose-<cli>-<pid>.log (default ~/.claude/handoffs), mode 0600.

usage: autoclose.py [--delay S]
exit:  0 = close scheduled, 1 = no iTerm2 tab / module missing (close by hand), 2 = error
Needs the iterm2 Python module and iTerm2's Python API enabled (iTerm2 > Settings >
General > Magic > Enable Python API). Without the module in this Python, the script
restarts itself with $HANDOFF_ITERM2_PYTHON or ~/.local/share/perfect-handoff/venv.
"""
import asyncio
import glob
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import phself  # noqa: E402

try:
    import iterm2
except ImportError:
    phself.reexec_for_iterm2()
    print("MANUAL: Python module 'iterm2' is missing (./install.sh --iterm2, or pip install iterm2).")
    sys.exit(1)

SESS_DIR = os.path.expanduser("~/.claude/sessions")
LOG_DIR = os.path.expanduser(os.environ.get("HANDOFF_DIR", "~/.claude/handoffs"))
BG_CHECK = os.path.join(HERE, "bg_check.sh")
IDLE_TIMEOUT = 900  # s: longest wait for the final message to finish
QUIET = 6           # s: screen without change = turn is over (CLIs without a registry)
RULE = re.compile(r"\s*[╭┌]?[─━]{20,}")   # line above an input box
PROMPT_GLYPHS = ("❯", ">", "›")                       # ❯ > ›
# Hints that the CLIs show only while a turn runs (lower case, bottom of the screen).
BUSY = ("esc to interrupt", "esc to cancel", "ctrl+c:cancel", "generating...", "generating…")


def entry(sid):
    for f in glob.glob(os.path.join(SESS_DIR, "*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        pid = d.get("pid") if isinstance(d, dict) else None
        if isinstance(pid, int) and not isinstance(pid, bool) and pid > 1 and d.get("sessionId") == sid:
            return d
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def log(name, msg):
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    os.chmod(LOG_DIR, 0o700)
    fd = os.open(os.path.join(LOG_DIR, f".autoclose-{name}.log"),
                 os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
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


async def screen_lines(s):
    c = await s.async_get_screen_contents()
    return [c.line(i).string for i in range(c.number_of_lines)]


def input_text(lines):
    """What the user could have typed into: the input box - the lowest line that starts
    with a prompt glyph right below a box rule (also inside a box: "│ ❯ ... │"), plus
    every line below it up to the next rule (multi-line input). Typed spaces count; only
    the padding at the right end of a line does not. Without such a box: the whole
    screen with digits replaced, so clocks in a status line do not count."""
    for i in range(len(lines) - 1, 0, -1):
        t = lines[i].strip().strip("│|").strip()
        if RULE.match(lines[i - 1]) and t[:1] in PROMPT_GLYPHS:
            box = [lines[i].rstrip()]
            for more in lines[i + 1:]:
                if RULE.match(more) or more.strip()[:1] in ("╰", "└"):
                    break
                box.append(more.rstrip())
            return "input:" + "\n".join(box)
    return "screen:" + re.sub(r"\d", "0", "\n".join(lines))


def busy(lines):
    text = "\n".join(lines[-12:]).lower()
    return any(b in text for b in BUSY)


async def wait_quiet(s, pid):
    """CLIs without a registry: idle = same screen for QUIET s and no busy marker."""
    t0, last, since = time.time(), None, time.time()
    while time.time() - t0 < IDLE_TIMEOUT:
        if not alive(pid):
            return "session already ended"
        lines = await screen_lines(s)
        snap = re.sub(r"\d", "0", "\n".join(lines))
        if snap != last or busy(lines):
            last, since = snap, time.time()
        elif time.time() - since >= QUIET:
            return None
        await asyncio.sleep(1)
    return f"abort: not idle after {IDLE_TIMEOUT} s"


def wait_registry_idle(sid):
    t0 = time.time()
    while time.time() - t0 < IDLE_TIMEOUT:
        e = entry(sid)
        if not e or not alive(e["pid"]):
            return "session already ended"
        if e.get("status") == "idle":
            return None
        time.sleep(1)
    return f"abort: not idle after {IDLE_TIMEOUT} s"


def run_close(cli, pid, tty, sid, delay):
    name = f"{cli}-{pid}"
    if cli == "claude":
        reason = wait_registry_idle(sid)
        if reason:
            log(name, reason)
            return
    result = {}

    def same_tab():
        return alive(pid) and phself.tty_of(pid) == tty

    async def close(conn):
        s = await find_session(conn, tty) if same_tab() else None
        if not s:
            result["why"] = f"abort: tab {tty} is gone"
            return
        if cli != "claude":
            reason = await wait_quiet(s, pid)
            if reason:
                result["why"] = reason
                return
        before = stamp(entry(sid) or {}) if cli == "claude" else None
        typed = input_text(await screen_lines(s))
        await asyncio.sleep(delay)
        if cli == "claude":
            e2 = entry(sid)
            if not e2 or stamp(e2) != before:
                result["why"] = "abort: session became active again"
                return
        lines = await screen_lines(s)
        if input_text(lines) != typed:
            result["why"] = "abort: screen changed (the user typed something)"
            return
        if cli != "claude" and busy(lines):
            result["why"] = "abort: session became active again"
            return
        bg = subprocess.run([BG_CHECK, "--pid", str(pid)], capture_output=True, text=True)
        if bg.returncode != 0:
            result["why"] = "abort: bg_check.sh exit %d: %s" % (bg.returncode, bg.stdout.strip()[:300])
            return
        if not same_tab() or await find_session(conn, tty) is None:
            result["why"] = f"abort: tab {tty} is gone"
            return
        await s.async_close(force=True)
        result["why"] = "tab closed"

    iterm2.run_until_complete(close)
    log(name, result.get("why", "abort: unknown"))


def main():
    args = sys.argv[1:]
    delay = 10
    if "--delay" in args:
        try:
            delay = max(3, min(120, int(args[args.index("--delay") + 1])))
        except (IndexError, ValueError):
            print("ERROR: --delay needs a number of seconds.", file=sys.stderr)
            sys.exit(2)
    if "--run" in args:  # internal: the detached watcher
        try:
            i = args.index("--run")
            cli, pid, tty, sid = args[i + 1], int(args[i + 2]), args[i + 3], args[i + 4]
        except (IndexError, ValueError):
            sys.exit(2)
        run_close(cli, pid, tty, None if sid == "-" else sid, delay)
        return

    me = phself.find()
    if not me:
        print("ERROR: no claude, codex, agy or grok process among the ancestors.", file=sys.stderr)
        sys.exit(2)
    cli, pid, tty, sid = me["cli"], me["pid"], me["tty"], me["sid"]
    if not tty:
        print("MANUAL: session has no terminal (tty).")
        sys.exit(1)
    if cli == "claude":
        e = entry(sid) if sid else None
        if not e or e.get("pid") != pid:
            print("ERROR: own Claude Code session not found in the session registry.", file=sys.stderr)
            sys.exit(2)

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
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--delay", str(delay),
                      "--run", cli, str(pid), tty, sid or "-"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    log(f"{cli}-{pid}", f"scheduled: {cli}, iTerm2 {found['id'][:8]} ({tty}), {delay} s after idle")
    print(f"AUTO: tab {tty} closes {delay} s after the final message.")
    sys.exit(0)


if __name__ == "__main__":
    main()
