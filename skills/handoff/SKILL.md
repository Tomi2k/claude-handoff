---
name: handoff
description: Goal-focused handoff of a long Claude Code session into a fresh one. Finishes the running step first, distils only the context that serves the goal into a handover file, opens a new iTerm2 tab (or a remote tmux session), carries the session name over as "... - Part N", waits for background work, and closes the old tab by itself. Triggers "/handoff", "handoff", "hand off the session", "continue in a new session", or a [CONTEXT-WATCHER] note. Usage /handoff [remote] [goal in your own words]
---

# /handoff - goal-focused session handoff

Moves ONLY the goal-relevant context of this session into a fresh session. A long
session gets worse as its context fills up; a fresh session with a short, precise
handover file works in the sharpest part of the window again.

Two modes:
- **local** (default): a new tab in the current iTerm2 window on macOS.
- **remote**: the handover goes to a server over SSH and Claude Code runs there in a
  tmux session. It keeps running when the laptop is closed; you can attach from a phone.

Arguments: if the argument starts with `remote`, the rest is the goal. Otherwise all of
it is the goal. No goal given: ask ONE question, "What should the new session achieve?".
Never invent the goal - the user sets it, and only context that serves it is carried over.
If a `[CONTEXT-WATCHER]` note triggered the handoff, the goal is the user's open
assignment in their own words, when it is unambiguous. Otherwise ask.

`<SESSION_ID>` below is your own session id. Claude Code shows it in the scratchpad path
of your system prompt (`.../<SESSION_ID>/scratchpad`). Never guess it.
Scripts live in `~/.claude/skills/handoff/scripts/`, the hook in `~/.claude/skills/handoff/hooks/`.

## Step 0 - Preparation (before the handover file)

### 0.1 Finish the running step

A handoff in the middle of a step causes errors and costs the new session a lot of
context. A step is the work you are doing right now, or the work the user assigned last,
for example "refactor function X, tests green".

1. Measure the context:
   `python3 ~/.claude/skills/handoff/hooks/context_watcher.py --status "<SESSION_ID>"`.
   It prints the fill level and the budget: 10 % of the window, at most up to 85 %.
2. Decide the case:
   - **A - step done and verified:** go on with 0.2.
   - **B - step running, the rest fits into the budget:** finish and verify the step.
     Do not start a new step. Then go on with 0.2.
   - **C - the rest does not fit, or the context is at 85 % or more:** work only up to
     the next clean stopping point: no half-done edit, build and tests in a known state.
     Then go on with 0.2.
3. In case B or C, tell the user in one sentence before you keep working:
   "I will finish <step> first, then hand off."
4. If the user explicitly wants the handoff right now, case C applies without waiting.

Estimate honestly. If the rest is unclear, case C applies. Write the case into the Mode
section of the handover file.

### 0.2 Background inventory

Check what is still running in THIS session in the background:

```bash
~/.claude/skills/handoff/scripts/bg_check.sh "<SESSION_ID>"
```

The script only sees shells (Bash with run_in_background, Monitor). Add the background
agents and workflows you started that have not reported back yet. For step 1:
- Endless work (dev server, watcher, `tail -f`) dies with this session. Put the start
  command under "Traps" so the new session can start it itself.
- Finite work with a goal-relevant result (test, build, deploy, agent): write under
  "State": "Result of <X> follows as `## Addendum` at the end of this file. Re-read
  this file before <step>."

## Step 1 - Write the handover file

Path: `${HANDOFF_DIR:-~/.claude/handoffs}/<YYYYMMDD-HHMM>-<short-slug>.md`. Create the
folder with `mkdir -p -m 700` if needed; the file can hold sensitive session context. Date via `date +%Y%m%d-%H%M`.

Structure (keep every section, but filter RADICALLY by the goal - what does not serve
the goal goes, however interesting it was):

```markdown
# Handoff: <goal in one sentence>
Created: <date/time> | Source: session in <cwd>

## Goal
<precise and checkable - how does the new session know it is done?>

## State (verified)
<what is done AND verified; what is done but unverified - keep them apart>

## Relevant files
<absolute paths + one line each on why they matter>

## Decisions made
<the user's decisions with their reason, so the new session does not reopen them>

## Mode
Mode: <CONTINUE or CONFIRM - see the rule below>
Case from 0.1: <A, B or C>
Assignment status: <OPEN or DONE>
Assignment (user's words, date/time): "<quote>"
Open assigned work: <exactly scoped, or: none>
Done when: <checkable criterion for the open work>
Afterwards: report to the user and STOP. No self-made follow-up tasks.

## Next steps
### Assigned
<ordered list ONLY from the user's assignment; first step small enough to act on
immediately; empty if the assignment is done>
### Suggestions (not assigned)
<your own ideas for later; the new session NEVER runs them without the user's OK>

## Traps
<known gotchas, failed approaches (so they are not repeated), permissions>
```

**Choosing the mode.** A handoff is usually a context transfer, not a starting gun.
Failure seen in practice: the new session kept working although the assignment was
already done, and then invented its own follow-up tasks. So a fixed test decides:

`CONTINUE` only if ALL four points hold:
1. The user assigned work that is demonstrably not done yet.
2. You can quote the assignment: the user's words with date or time.
3. No open decision of the user blocks this work.
4. The context watcher or the context limit triggered the handoff - or the user
   explicitly says "keep going" / "continue right away" when asking for the handoff.

Otherwise `CONFIRM`. When in doubt, `CONFIRM`. Your own suggestion is never an
assignment. If the assignment is done, it is always `CONFIRM` with "Assignment status:
DONE" and an empty "Assigned" list.

Behaviour of the new session (the start prompt repeats it; a missing Mode section
means CONFIRM):
- **CONTINUE:** first check that the open assigned work is really still open (files,
  `git status`, tests). If it is already done, behave as CONFIRM. Otherwise continue
  ONLY that work until "Done when" holds, then report and stop.
- **CONFIRM:** do not start working. Summarise goal, context and state in a few
  sentences. Name the first item under "Assigned" and ask: "Do you want me to do
  <step> next?" If "Assigned" is empty, say "The assignment is done." and offer the
  suggestions as options. Then wait.

**Never in the file:** secrets, tokens, passwords, `.env` contents, customer credentials.
Point to where they live instead ("credentials: password manager entry X").

## Step 2a - local mode: new tab in the current iTerm2 window

**Carry the name over.** If the current session has a name, the new session gets the
same name with a counter ("... - Part 2", "... - Part 3") via a real `/rename`.
Always read the name fresh at handoff time - users rename sessions as the goal shifts.
Never take it from memory or from an earlier handover file.

```bash
INFO=$(~/.claude/skills/handoff/scripts/handoff_title.sh current "<SESSION_ID>")  # "name|id" or empty
NEW_NAME=$(~/.claude/skills/handoff/scripts/handoff_title.sh next "${INFO%%|*}")   # empty if unnamed
~/.claude/skills/handoff/scripts/handoff_launch.sh "<PROJECT_DIR>" "<HANDOVER_PATH>" "$NEW_NAME"
```

The launcher opens a new TAB in the current iTerm2 window (a new window only if none is
open), waits up to ~95 s until the rename is typed, and prints the new name - tell the
user. On "new session not found" the tab still started; only the rename is missing, so
ask the user to run `/rename` once. Optional: `HANDOFF_MODEL=<alias>` picks the model.
`HANDOFF_SKIP_PERMISSIONS=1` starts the new session in bypass mode. Never set it on your
own: only when the user asked for it in this conversation or set it in their environment.

Then report: new tab is running, its name, and the handover path as a clickable
`file://` URL. The permission to close this tab comes ONLY from step 3.

## Step 2b - remote mode: the session moves to a server

Needs `HANDOFF_REMOTE_HOST` (an SSH alias) and Claude Code logged in on the server.
On the server, handovers go to `~/handoffs`, repositories to `~/projects/<repo>`.
`<repo>` and `<slug>` must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` - check this before you
build any command. Never set `HANDOFF_SKIP_PERMISSIONS` or bypass flags on the server
unless the user asked for it in this conversation.

1. **Check first:**
   `ssh -o ConnectTimeout=5 -o BatchMode=yes "$HANDOFF_REMOTE_HOST" 'claude --version && mkdir -p -m 700 ~/handoffs ~/projects'`.
   Not reachable or Claude Code missing: stop and tell the user what is missing.
2. **Repository state** (only for git projects): check `git status`. Uncommitted
   goal-relevant changes: ask the user whether committing and pushing is OK (never
   commit unasked). Without a push the server works on an old state - say so clearly.
   Then clone or update on the server:
   `ssh "$HANDOFF_REMOTE_HOST" 'cd ~/projects && if [ -d <repo> ]; then git -C <repo> pull --ff-only; else git clone -- "<url>" <repo>; fi'`.
   Copy git-ignored but goal-relevant work files with `rsync`.
3. **Copy the handover and start the session.** Build the start command as a one-shot
   script quoted with `printf %q` (never splice the prompt into nested ssh quotes):
   ```bash
   S=$(mktemp)
   { printf 'cd ~/projects/%q || exit 1\n' "<repo>"; printf 'exec claude %q\n' "<START_PROMPT>"; } > "$S"
   scp "<HANDOVER_PATH>" "$HANDOFF_REMOTE_HOST":handoffs/
   scp "$S" "$HANDOFF_REMOTE_HOST":handoffs/start-<slug>.sh && rm -f "$S"
   ssh "$HANDOFF_REMOTE_HOST" 'tmux new-session -d -s handoff-<slug> bash ~/handoffs/start-<slug>.sh'
   ```
   `<START_PROMPT>` is the prompt from `handoff_launch.sh`, with the remote handover path.
4. **Follow-up:** wait ~25 s, then `ssh "$HANDOFF_REMOTE_HOST" 'tmux capture-pane -t handoff-<slug> -p | tail -15'`.
   If the trust dialog "Is this a project you created or one you trust?" shows up, do
   NOT answer it yourself: trusting a repository lets its hooks and MCP settings run code.
   Tell the user to attach and decide - unless they said in this conversation that this
   repository is theirs and may be trusted. Never type `/rename` into a dialog; wait for
   the input prompt first, then send `/rename <name>` and `Enter` with `tmux send-keys`.
5. **Report:** tmux session name, attach command
   `ssh -t "$HANDOFF_REMOTE_HOST" 'tmux attach -t handoff-<slug>'`. The permission to
   close the local tab comes ONLY from step 3.

## Step 3 - Wrap-up: check the background, then the closing line (both modes)

After the handoff, shells or agents of this session sometimes keep running. If the user
closes the terminal too early, that work dies. So the last line is ALWAYS exactly one of
the fixed lines below. When everything is done, the iTerm2 tab closes itself (point 5).

1. Check the shells again: `~/.claude/skills/handoff/scripts/bg_check.sh "<SESSION_ID>"`.
   Exit 0 = no shell. Exit 1 = shells running (pid, runtime, command).
   Exit 2 = claude process not found: retry once without the session id.
2. Check the open background agents, workflows and monitors from 0.2 yourself. The
   script cannot see agents or workflows.
3. If something is running, decide per item:
   - Finite work: wait. No polling, no `sleep`. Its completion notification wakes this
     session automatically.
   - Endless work: it never ends by itself. Stop it (TaskStop) when its start command is
     in the handover file (0.2). If stopping is unsafe (deploy, migration, someone else's
     process), ask the user.
   - End the turn. The last line is exactly:
     `⏳ Do NOT close this terminal yet. <N> background processes are still running. I will report here when everything is done.`
     Above it: the list, each process with name or command and runtime.
4. When a completion notification arrives and the result is goal-relevant:
   1. Append it to the handover file as `## Addendum <HH:MM>` with the result and the
      path of the output file. In remote mode, update the server copy too.
   2. Local mode: send the new session one sentence pointing to the addendum
      (SendMessage; ListAgents shows it under its new name).
   3. Then continue with point 1.
5. If nothing is running any more (exit 0 and no open agent): schedule the auto-close.
   This is the LAST tool call of this session:
   ```bash
   "${HANDOFF_ITERM2_PYTHON:-python3}" ~/.claude/skills/handoff/scripts/autoclose.py "<SESSION_ID>" --delay 10
   ```
   The script finds this session's iTerm2 tab by its tty (terminal device), starts a
   detached watcher and returns at once. The watcher waits until the session is idle -
   that is, until your final message is complete - then 10 s more, and closes ONLY this
   tab. It aborts if the session becomes active again meanwhile (the user types, a
   notification arrives) or if `bg_check.sh` finds shells.
   - Exit 0 (`AUTO: ...`): the last line of the final message is exactly:
     `✅ All done. This terminal closes itself in 10 s. If it stays open, close it with Cmd+W.`
   - Exit 1 (`MANUAL: ...`, e.g. not iTerm2, module missing) or exit 2: the last line is exactly:
     `✅ You can and should close this terminal now. (Cmd+W closes only this tab.)`
   Nothing comes after this line: no tool call, no question, no offer.
6. If the check fails even without the session id: give no closing line. The last line
   is exactly:
   `⚠️ Background check failed. I cannot say for sure whether this terminal may be closed.`
   Above it: the error and the background tasks you know of.

If another background notification arrives after the closing line, step 3 applies again
and the last line is again the matching one. If the user types into this tab, they want
to keep it: do not schedule another auto-close unless they ask.

**Cmd+W, not Cmd+Shift+W:** the launcher opens the new session as a tab in the SAME
iTerm2 window. Closing the whole window ends the new session as well. `autoclose.py`
closes only the tab with this session's tty. If that tab is the last one in its window,
iTerm2 closes the window with it.

## Principles

- The handoff is a DISTILLATION, not an export. Better 60 precise lines than 600
  complete ones. Test: could a colleague without access to this session continue
  productively with the file alone?
- ALWAYS document failed approaches under "Traps", so the new session does not walk
  into the same dead ends.
- After the new session has started, do not work on the project in THIS session any
  more (split-brain risk). Only step 3 is allowed: wait for background work, deliver
  addenda, stop endless processes.
- The last line of the last message of this session is ALWAYS one of the fixed lines
  from step 3. Never write "can be closed" without the check.
