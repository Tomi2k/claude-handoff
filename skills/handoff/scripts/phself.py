#!/usr/bin/env python3
"""Which agent CLI runs this script, and in which terminal tab?

Walks up the process tree to the NEAREST claude / codex / agy / grok process. The nearest
one wins: when one CLI was started from another, the inner one is "you".
Prints one line, tab-separated:  <cli> <pid> <tty or -> <session id or ->

The session id comes from the variable that CLI sets for its tool shells:
  claude CLAUDE_CODE_SESSION_ID   codex CODEX_THREAD_ID
  agy    ANTIGRAVITY_CONVERSATION_ID   grok GROK_SESSION_ID
These are internal details of each CLI and may change with an update.

usage: phself.py            exit: 0 = found, 1 = no supported CLI among the ancestors
Also importable: phself.find() -> dict or None.
"""
import os
import re
import subprocess
import sys

SESSION_VARS = {
    "claude": "CLAUDE_CODE_SESSION_ID",
    "codex": "CODEX_THREAD_ID",
    "agy": "ANTIGRAVITY_CONVERSATION_ID",
    "grok": "GROK_SESSION_ID",
}
ID_RE = re.compile(r"[0-9A-Za-z_-]{8,64}")


def ps(pid, field):
    out = subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)],
                         capture_output=True, text=True).stdout
    return out.strip()


def tty_of(pid):
    t = ps(pid, "tty")
    return "/dev/" + t if t and t != "??" else None


def reexec_for_iterm2():
    """The iterm2 module is missing in this Python: restart the same script with a Python
    that has it - $HANDOFF_ITERM2_PYTHON (the user's setting) or the venv that
    install.sh --iterm2 creates. Returns only if there is none."""
    if os.environ.get("PH_REEXEC") == "1":
        return
    for cand in (os.environ.get("HANDOFF_ITERM2_PYTHON"),
                 os.path.expanduser("~/.local/share/perfect-handoff/venv/bin/python")):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK) \
                and os.path.abspath(cand) != os.path.abspath(sys.executable):
            os.environ["PH_REEXEC"] = "1"
            os.execv(cand, [cand] + sys.argv)


def find(start=None):
    pid = start or os.getppid()
    for _ in range(64):
        if pid <= 1:
            return None
        name = os.path.basename(ps(pid, "comm"))
        if name in SESSION_VARS:
            sid = os.environ.get(SESSION_VARS[name], "")
            return {"cli": name, "pid": pid, "tty": tty_of(pid),
                    "sid": sid if ID_RE.fullmatch(sid) else None}
        try:
            pid = int(ps(pid, "ppid") or 0)
        except ValueError:
            return None
    return None


if __name__ == "__main__":
    me = find()
    if not me:
        print("ERROR: no claude, codex, agy or grok process among the ancestors.", file=sys.stderr)
        sys.exit(1)
    print("\t".join([me["cli"], str(me["pid"]), me["tty"] or "-", me["sid"] or "-"]))
