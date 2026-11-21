#!/usr/bin/env python3
"""UserPromptSubmit hook: suggests /handoff once the context window fills up.

Reads the last assistant entry with `usage` from the transcript and injects an
additionalContext note when the threshold is reached. After that it stays quiet
until the fill level has grown by another 10 points (no nagging).

The note never says "stop now": the agent first finishes the running step if the rest
fits into 10 % of the window (up to a hard limit of 85 %), otherwise it works up to the
next clean stopping point. Then it runs the handoff skill.

Configuration (environment):
  CLAUDE_CONTEXT_WINDOW   window size in tokens (default: 1,000,000 if the model in
                          settings.json contains "[1m]", else 200,000)
  HANDOFF_WATCH_AT        fraction of the window that triggers the note (default 0.50)
  HANDOFF_WATCH_TOKENS    absolute token count that triggers the note, whichever comes
                          first (optional; e.g. 150000 for large windows)
  HANDOFF_DIR             state folder (default ~/.claude/handoffs)

CLI for the skill:  context_watcher.py --status <SESSION_ID>
"""
import glob
import json
import os
import re
import sys

STEP = 0.10            # re-notify only after another 10 points
FINISH_BUDGET = 0.10   # share of the window allowed to finish a running step
HARD_LIMIT = 0.85      # from here on: no finishing, only a clean stop

CONFIG_DIR = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
STATE_DIR = os.path.expanduser(os.environ.get("HANDOFF_DIR", "~/.claude/handoffs"))


def window_size():
    env = os.environ.get("CLAUDE_CONTEXT_WINDOW")
    if env and env.isdigit():
        return int(env)
    try:
        with open(os.path.join(CONFIG_DIR, "settings.json"), encoding="utf-8") as f:
            model = json.load(f).get("model", "")
    except (OSError, ValueError):
        model = ""
    return 1_000_000 if "[1m]" in model else 200_000


def threshold(window):
    try:
        frac = float(os.environ.get("HANDOFF_WATCH_AT", "0.5"))
    except ValueError:
        frac = 0.5
    tokens = os.environ.get("HANDOFF_WATCH_TOKENS", "")
    if tokens.isdigit() and int(tokens) > 0:
        frac = min(frac, int(tokens) / window)
    return frac


WINDOW = window_size()
THRESHOLD = threshold(WINDOW)


def last_usage(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 400_000))
            tail = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in reversed(tail):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        u = (e.get("message") or {}).get("usage") if isinstance(e, dict) else None
        if u and "input_tokens" in u:
            return (u.get("input_tokens", 0)
                    + u.get("cache_read_input_tokens", 0)
                    + u.get("cache_creation_input_tokens", 0))
    return None


def status(sid):
    if not re.fullmatch(r"[0-9A-Za-z-]{8,64}", sid):
        print("ERROR: unexpected session id.")
        sys.exit(2)
    paths = glob.glob(os.path.join(CONFIG_DIR, "projects", "*", f"{sid}.jsonl"))
    used = last_usage(paths[0]) if paths else None
    if not used:
        print("ERROR: no transcript with usage data found for this session.")
        sys.exit(2)
    frac = used / WINDOW
    budget = min(int(WINDOW * FINISH_BUDGET), max(0, int(WINDOW * HARD_LIMIT) - used))
    print(f"Context: {used // 1000}k of {WINDOW // 1000}k tokens ({int(frac * 100)} %).")
    if frac >= HARD_LIMIT:
        print(f"Finish the running step: no, context is at {int(HARD_LIMIT * 100)} % or more (case C).")
    else:
        print(f"Finish the running step: yes, budget {budget // 1000}k tokens "
              f"(10 % of the window, at most up to {int(HARD_LIMIT * 100)} %).")


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--status":
        status(sys.argv[2])
        return
    try:
        inp = json.load(sys.stdin)
    except ValueError:
        return
    tp = inp.get("transcript_path")
    sid = str(inp.get("session_id", "unknown"))
    if not re.fullmatch(r"[0-9A-Za-z-]{1,64}", sid):
        return
    if not tp or not os.path.exists(tp):
        return
    used = last_usage(tp)
    if not used:
        return
    frac = used / WINDOW
    if frac < THRESHOLD:
        return

    state_file = os.path.join(STATE_DIR, f".watch-{sid}")
    last_warned = 0.0
    try:
        with open(state_file, encoding="utf-8") as f:
            last_warned = float(f.read().strip() or 0)
    except (OSError, ValueError):
        pass
    if last_warned >= THRESHOLD and frac < last_warned + STEP:
        return
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(state_file, "w", encoding="utf-8") as f:
        f.write(f"{frac:.3f}")

    pct = int(frac * 100)
    budget = int(WINDOW * FINISH_BUDGET)
    if frac >= HARD_LIMIT:
        step_rule = (f"The context is nearly full ({int(HARD_LIMIT * 100)} % or more): do not finish "
                     f"the step any more. Only reach a clean stopping point (no half-done edit), "
                     f"then hand off right away.")
    else:
        step_rule = (f"If a step is running (including the one just assigned), finish and verify "
                     f"it first when the rest fits into about {budget} tokens (10 % of the window). "
                     f"If it does not fit, work up to the next clean stopping point. "
                     f"Do not start a new step.")
    msg = (f"[CONTEXT-WATCHER] The context window is ~{pct} % full ({used} of {WINDOW} tokens). "
           f"Prepare the /handoff skill (Skill tool, skill: \"handoff\"), but do not abort anything. "
           f"{step_rule} Then follow step 0 of the skill. Do not invent the goal of the new "
           f"session: if it is not clear from the user's assignment, ask.")
    print(json.dumps({
        "systemMessage": f"Context {pct} % - handoff suggested",
        "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": msg},
    }))


if __name__ == "__main__":
    main()
