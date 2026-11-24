#!/usr/bin/env -S python3 -I
"""Handoff wrap-up: closes the iTerm2 tab of your own agent session by itself - but only
when every check passes. On any doubt the tab stays open and the user closes it.

Works for Claude Code, Codex, agy and Grok. The script finds its own CLI by walking up
the process tree (phself.py): CLI pid -> tty -> the iTerm2 session with the same tty.
Without --run it checks that the tab can be found and then restarts itself detached
(own process group) with --run and that exact identity.

--run waits until the session is idle (the final message is done):
  claude  the session registry says "idle" (~/.claude/sessions/*.json)
  others  the screen stops changing for QUIET seconds and shows no busy hint
It aborts WITHOUT closing
  - if no input box is recognised, the input box is not empty, or the terminal cursor is
    not directly behind the prompt glyph (so a draft of spaces or empty lines also counts),
  - if, during the DELAY seconds that follow (checked every second), the input box or the
    cursor changes, the session becomes active again (claude: registry or busy hint;
    others: any change on the screen or a busy hint), or
  - if bg_check.sh does not report "no background shell", or
  - if the CLI is no longer in the foreground of that exact iTerm2 session.
Otherwise it closes only that tab (async_close with force).
Log: $HANDOFF_DIR/.autoclose-<cli>-<pid>.log (default ~/.claude/handoffs), mode 0600,
without command text.

usage: autoclose.py [--delay S]
exit:  0 = close scheduled, 1 = no iTerm2 tab / module missing (close by hand), 2 = error
Needs the iterm2 Python module and iTerm2's Python API enabled (iTerm2 > Settings >
General > Magic > Enable Python API). Without the module in this Python, the script
restarts itself with ~/.local/share/perfect-handoff/venv (install.sh --iterm2).
"""
import asyncio
import glob
import json
import os
import re
import stat
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
    print("MANUAL: Python module 'iterm2' is missing (./install.sh --iterm2).")
    sys.exit(1)

SESS_DIR = os.path.expanduser("~/.claude/sessions")
LOG_DIR = os.path.expanduser(os.environ.get("HANDOFF_DIR", "~/.claude/handoffs"))
BG_CHECK = os.path.join(HERE, "bg_check.sh")
IDLE_TIMEOUT = 900  # s: longest wait for the final message to finish
QUIET = 6           # s: screen without change = turn is over (CLIs without a registry)
RULE = re.compile(r"\s*[╭┌]?[─━]{20,}")  # line above an input box
# Hints that the CLIs show only while a turn runs (lower case, bottom of the screen).
BUSY = ("esc to interrupt", "esc to cancel", "ctrl+c:cancel", "generating...", "generating…")
# Grey hint texts that a CLI shows in an EMPTY input box. Exact texts only: a pattern that
# also matches typed text would throw a draft away. An unknown hint keeps the tab open.
PLACEHOLDERS = {
    "claude": (re.compile(r'Try "[^"]*"'),),
    "codex": (re.compile(r"Ask Codex to do anything|Ask a follow-up question"),),
    "agy": (),
    "grok": (),
}


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
    """Append to the private log. Never follows a symlink (folder or file), skips a folder
    of another user and never changes the mode of a folder that exists already."""
    try:
        os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
        st = os.lstat(LOG_DIR)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            return
        fd = os.open(os.path.join(LOG_DIR, f".autoclose-{name}.log"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    except OSError:
        return
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def stamp(e):
    return (e.get("status"), e.get("statusUpdatedAt"), e.get("updatedAt"))


def in_foreground(pid, cli, tty):
    """The CLI still runs in the foreground of its terminal (not suspended, no editor on top)."""
    out = subprocess.run(["ps", "-o", "stat=,comm=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out or "+" not in out.split()[0]:
        return False
    return os.path.basename(out.split(None, 1)[1]) == cli and phself.tty_of(pid) == tty


async def find_session(conn, tty):
    app = await iterm2.async_get_app(conn)
    for w in app.terminal_windows:
        for t in w.tabs:
            for s in t.sessions:
                if await s.async_get_variable("tty") == tty:
                    return s
    return None


async def screen(s):
    """The visible screen as text lines, and the cursor as (row on the screen, column)."""
    c = await s.async_get_screen_contents()
    li = await s.async_get_line_info()
    lines = [c.line(i).string.replace("\x00", " ").replace("\xa0", " ")
             for i in range(c.number_of_lines)]
    row = c.cursor_coord.y - li.overflow - li.scrollback_buffer_height
    return lines, (row, c.cursor_coord.x)


def input_box(lines, cli):
    """The input box: the lowest line that starts with the prompt glyph of this CLI. Codex
    shows a bare "›"; the others show "❯" or ">" right below a box rule (also inside a box
    "│ ❯ ... │"). Returns (text after the glyph, row, column behind "glyph + space"), or
    None if no box is recognised. Below a rule-framed box every line up to the closing rule
    belongs to the box, also behind an empty line. Codex has no closing rule: its box ends
    at the first empty line, and the cursor check covers what follows."""
    n = len(lines)
    while n and not lines[n - 1].strip():
        n -= 1
    for i in range(n - 1, max(-1, n - 31), -1):
        t = lines[i].strip().strip("│|").strip()
        glyph, above = t[:1], (lines[i - 1] if i > 0 else "")
        if cli == "codex":
            ok = glyph == "›" and lines[i].startswith("›")
        else:
            ok = glyph in ("❯", ">") and bool(RULE.match(above))
        if not ok:
            continue
        box, closed = [t[1:].strip()], cli == "codex"
        for more in lines[i + 1:n]:
            m = more.strip().strip("│|").strip()
            if RULE.match(more) or more.strip()[:1] in ("╰", "└"):
                closed = True
                break
            if not m and cli == "codex":
                break
            box.append(m)
        if not closed:
            return None     # no closing rule below the prompt: not a box we know
        return "\n".join(box).rstrip("\n"), i, lines[i].index(glyph) + 2
    return None


def is_empty(box, cursor, cli):
    """Empty = no text (or exactly a known hint text) AND the cursor right behind the glyph.
    Typed spaces or line breaks move the cursor, so they count as a draft."""
    text, row, col = box
    if cursor != (row, col):
        return False
    t = text.strip()
    return t == "" or any(p.fullmatch(t) for p in PLACEHOLDERS[cli])


def busy(lines):
    text = "\n".join(lines[-12:]).lower()
    return any(b in text for b in BUSY)


async def wait_quiet(s, pid):
    """CLIs without a registry: idle = same screen for QUIET s and no busy hint."""
    t0, last, since = time.time(), None, time.time()
    while time.time() - t0 < IDLE_TIMEOUT:
        if not alive(pid):
            return "session already ended"
        lines, _ = await screen(s)
        snap = "\n".join(lines)
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


def run_close(cli, pid, tty, sid, iterm_id, delay):
    name = f"{cli}-{pid}"
    if cli == "claude":
        reason = wait_registry_idle(sid)
        if reason:
            log(name, reason)
            return
    result = {}

    async def close(conn):
        s = await find_session(conn, tty) if alive(pid) and phself.tty_of(pid) == tty else None
        if not s or s.session_id != iterm_id:
            result["why"] = f"abort: tab {tty} is gone or not the same iTerm2 session"
            return
        if cli != "claude":
            reason = await wait_quiet(s, pid)
            if reason:
                result["why"] = reason
                return
        before = stamp(entry(sid) or {}) if cli == "claude" else None
        lines, cursor = await screen(s)
        box, first = input_box(lines, cli), "\n".join(lines)
        if box is None:
            result["why"] = "abort: no input box recognised - close by hand"
            return
        if not is_empty(box, cursor, cli):
            result["why"] = "abort: the input box is not empty (a draft stays)"
            return
        if busy(lines):
            result["why"] = "abort: the screen shows a busy hint"
            return
        for _ in range(delay):          # watch every second, not only at the end
            await asyncio.sleep(1)
            lines, cur2 = await screen(s)
            if input_box(lines, cli) != box or cur2 != cursor:
                result["why"] = "abort: the input box changed (the user typed something)"
                return
            if busy(lines):
                result["why"] = "abort: session became active again"
                return
            if cli == "claude":
                e2 = entry(sid)
                if not e2 or e2.get("status") != "idle" or stamp(e2) != before:
                    result["why"] = "abort: session became active again"
                    return
            elif "\n".join(lines) != first:
                result["why"] = "abort: session became active again"
                return
        bg = subprocess.run([BG_CHECK, "--pid", str(pid)], capture_output=True, text=True)
        if bg.returncode != 0:
            result["why"] = f"abort: bg_check.sh exit {bg.returncode} (background work or unknown state)"
            return
        if not in_foreground(pid, cli, tty) or await find_session(conn, tty) is None:
            result["why"] = "abort: the CLI is not in the foreground of its tab any more"
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
    if "--run" in args:  # internal: the detached watcher, started below with checked values
        try:
            i = args.index("--run")
            cli, pid, tty, sid, iterm_id = args[i + 1], int(args[i + 2]), args[i + 3], args[i + 4], args[i + 5]
        except (IndexError, ValueError):
            sys.exit(2)
        sid = None if sid == "-" else sid
        if cli not in phself.SESSION_VARS or not in_foreground(pid, cli, tty):
            sys.exit(2)
        if cli == "claude":   # the registry entry of that session id must be this very process
            e = entry(sid) if sid else None
            if not e or e.get("pid") != pid:
                sys.exit(2)
        run_close(cli, pid, tty, sid, iterm_id, delay)
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
    subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--delay", str(delay),
                      "--run", cli, str(pid), tty, sid or "-", found["id"]],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    log(f"{cli}-{pid}", f"scheduled: {cli}, iTerm2 {found['id'][:8]} ({tty}), {delay} s after idle")
    print(f"AUTO: tab {tty} closes {delay} s after the final message, if every check passes.")
    sys.exit(0)


if __name__ == "__main__":
    main()
