#!/usr/bin/env -S python3 -I
"""Checks a handover file before it is handed to a new session or copied to a server.

A new session is told to follow this file, so only the user's own, fresh handover file in
the handover folder is accepted: never a symlink, a file of another user, a file that
others can read or write, a file somewhere in a project, or an old file.

usage: handoff_check.py <absolute path of the handover file>
exit:  0 = accepted, 1 = refused (the reason is on stderr), 2 = bad arguments
env:   HANDOFF_DIR  handover folder (default ~/.claude/handoffs)
"""
import os
import re
import stat
import sys
import time

MAX_AGE = 900  # s: a handover file is written right before the handoff


def check(ho, folder):
    if not os.path.isabs(ho) or re.search(r"[\x00-\x1f\x7f]", ho):
        return "pass an absolute path without control characters"
    try:
        st = os.lstat(ho)
    except OSError:
        return "not found: " + ho
    if not stat.S_ISREG(st.st_mode):
        return "not a regular file (symlinks are not followed): " + ho
    if st.st_uid != os.getuid():
        return "not owned by you: " + ho
    if st.st_mode & 0o077:
        return "others can read or write it - run chmod 600 on it: " + ho
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.md", os.path.basename(ho)):
        return "unexpected file name (letters, digits, . _ - and the ending .md)"
    if ho != os.path.realpath(ho):
        return "pass the real path (no symlink and no .. in any folder of the path)"
    if os.path.dirname(ho) != os.path.realpath(folder):
        return "must be directly in the handover folder " + folder
    ds = os.lstat(os.path.dirname(ho))
    if not stat.S_ISDIR(ds.st_mode) or ds.st_uid != os.getuid() or ds.st_mode & 0o077:
        return "the handover folder must be your own folder with mode 700"
    if st.st_mtime > time.time() + 60:
        return "its time stamp is in the future - write a new handover file"
    if time.time() - st.st_mtime > MAX_AGE:
        return "older than 15 minutes - write a new handover file for this handoff"
    return None


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: handoff_check.py <absolute path of the handover file>\n")
        sys.exit(2)
    folder = os.path.expanduser(os.environ.get("HANDOFF_DIR") or "~/.claude/handoffs")
    if not os.path.isabs(folder):
        sys.stderr.write("ERROR: HANDOFF_DIR must be an absolute path\n")
        sys.exit(1)
    why = check(sys.argv[1], folder)
    if why:
        sys.stderr.write("ERROR: handover file: " + why + "\n")
        sys.exit(1)
