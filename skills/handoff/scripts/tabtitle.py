#!/usr/bin/env python3
"""Read or set the iTerm2 tab title of the tab whose session has a given tty.

This is the session name for CLIs without a usable rename command (Codex, agy, Grok).
"set" works like iTerm2's "Edit Tab Title", so a CLI that sends its own terminal title
does not overwrite it: the session ignores titles that the CLI sends. "get" prints the
title, or nothing if none was set.

usage: tabtitle.py set <tty> <title>
       tabtitle.py get <tty>
exit:  0 = done, 1 = no iTerm2 tab with that tty / iterm2 module or Python API missing,
       2 = bad arguments
Needs the iterm2 Python module and iTerm2's Python API (Settings > General > Magic).
Without the module in this Python, it restarts itself with $HANDOFF_ITERM2_PYTHON or
~/.local/share/perfect-handoff/venv (created by install.sh --iterm2).
"""
import os
import re
import sys

TTY_RE = re.compile(r"/dev/ttys?[0-9]{1,4}")


def clean(title):
    """Same allowlist as the launcher: letters, digits, space and . , _ + : - (en/em dash).
    iTerm2 interpolates \\( ... ) in tab titles; backslash and parentheses never pass."""
    t = re.sub(r"[^\w .,+:–—-]", "", title)
    return t.lstrip("-. ").strip()[:80]


def main():
    a = sys.argv[1:]
    if len(a) < 2 or a[0] not in ("get", "set") or not TTY_RE.fullmatch(a[1]) \
            or (a[0] == "set" and len(a) != 3):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    try:
        import iterm2
    except ImportError:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import phself
        phself.reexec_for_iterm2()
        print("MANUAL: Python module 'iterm2' is missing (./install.sh --iterm2, or pip install iterm2).")
        sys.exit(1)
    op, tty = a[0], a[1]
    title = clean(a[2]) if op == "set" else ""
    if op == "set" and not title:
        print("ERROR: title is empty after the character check.", file=sys.stderr)
        sys.exit(2)
    out = {}

    async def run(conn):
        app = await iterm2.async_get_app(conn)
        for w in app.terminal_windows:
            for t in w.tabs:
                for s in t.sessions:
                    if await s.async_get_variable("tty") == tty:
                        if op == "set":
                            # iTerm2 3.7 sometimes draws the session name instead of the
                            # tab title, and CLIs send their own titles. So: this session
                            # only (local profile copy) shows its name and ignores app titles.
                            p = iterm2.LocalWriteOnlyProfile()
                            p.set_allow_title_setting(False)
                            p.set_title_components([iterm2.TitleComponents.SESSION_NAME])
                            p.set_name(title)
                            await s.async_set_profile_properties(p)
                            await t.async_set_title(title)
                        out["title"] = title if op == "set" else \
                            (await t.async_get_variable("titleOverride") or "")
                        return

    try:
        iterm2.run_until_complete(run)
    except Exception as exc:  # API disabled, iTerm2 not running, ...
        print(f"MANUAL: iTerm2 Python API not reachable ({exc.__class__.__name__}).")
        sys.exit(1)
    if "title" not in out:
        print(f"MANUAL: no iTerm2 tab with {tty} found.")
        sys.exit(1)
    if out["title"]:
        print(out["title"])


if __name__ == "__main__":
    main()
