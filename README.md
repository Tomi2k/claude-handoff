<p align="center">
  <img src="assets/hero.png" alt="Session 1 fills up into the dumb zone. One handover file carries the goal into a clean Session 2." width="100%">
</p>

# claude-handoff

**Hand off a long Claude Code session to a fresh one - before the context window makes it dumb.**

A skill for [Claude Code](https://code.claude.com) made for terminal work in **iTerm2 on macOS**.
It finishes the step you are in, writes a short, goal-filtered handover file, opens a new
tab with a fresh session, gives it the same name with "- Part 2", waits until the old
session's background work is done, and then closes the old tab by itself.

```
/handoff finish the payment webhook and get the tests green
```

---

## Why this exists

### The first tokens are the smartest

Matt Pocock calls it the *smart zone*:

> "Early in a session the agent is in a 'smart zone' - sharp, focused, recall is good.
> As the session grows it drifts into a 'dumb zone': sloppier, forgetful, more mistakes."
> - [AI Hero, AI Coding Dictionary: Smart zone](https://www.aihero.dev/ai-coding-dictionary/smart-zone)

He puts the start of the dumb zone on frontier models at around 125K-150K tokens and adds
that this is debated. His advice: when a task is bigger than one smart zone, *hand off at a
natural boundary* and let a fresh session do the next piece.

Anthropic describes the same effect as **context rot**: "as the number of tokens in the
context window increases, the model's ability to accurately recall information from that
context decreases" - a gradient, not a hard cliff
([Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)).
Chroma measured it across 18 models: reliability drops as input grows, even on simple tasks
([Context Rot](https://research.trychroma.com/context-rot)).

### What I kept running into

In my own long Claude Code sessions, mistakes start to pile up from about half of the
context window: instructions from 20 turns ago are forgotten, fixed bugs come back. That is
my experience, not a benchmark. Large windows (1M tokens) do not fix it; they only make the
slow part longer.

Handing off by hand was not much better. These are the failures this skill fixes:

| Problem I hit | What the skill does |
|---|---|
| The session gets sloppy and I notice too late. | A hook measures the fill level on every prompt and suggests the handoff at a threshold you choose. |
| The handoff cut a step in half. The new session started with a half-done edit. | It finishes the running step first if the rest fits into 10 % of the window. Otherwise it stops at the next clean point. |
| The new session "continued" although the work was done, and invented its own next tasks. | A fixed rule decides between **CONTINUE** and **CONFIRM**. Assigned work and own suggestions are separate lists. Suggestions never run without your OK. |
| I copied context by hand and forgot the important part. | A goal-filtered handover file: state, decisions, files, next steps, traps - and nothing else. |
| Ten tabs, all called "claude". Which one was it? | The new session gets the old name plus "- Part 2" through a real `/rename`. |
| "Can I close this terminal now?" Background shells were still running. | It checks the old session's background work, waits for it, and ends with one fixed line. When everything is done, the old tab closes itself. |

---

## How it works

1. **Finish the step.** It measures the context and finishes the running step if the
   rest fits into the budget (10 % of the window, never past 85 %).
2. **Background inventory.** It lists background shells (dev servers, builds, agents)
   so nothing dies silently.
3. **Handover file.** `~/.claude/handoffs/<date>-<slug>.md` with goal, verified state,
   files, decisions, mode, next steps and traps. Filtered by the goal, no secrets.
4. **New session.** A new tab in the same iTerm2 window starts Claude Code with the
   handover file and is renamed to "<old name> - Part 2".
5. **Wrap-up.** The old session waits for its background work, delivers late results as
   an addendum, and ends with exactly one line:

   | Situation | Last line |
   |---|---|
   | Still running | `⏳ Do NOT close this terminal yet. ...` |
   | Done, iTerm2 | `✅ All done. This terminal closes itself in 10 s. ...` |
   | Done, other terminal | `✅ You can and should close this terminal now. (Cmd+W closes only this tab.)` |

   Type anything into the old tab within those 10 seconds and it stays open.

**Remote mode** (`/handoff remote <goal>`): the handover goes to a server over SSH and
Claude Code runs there in tmux. It keeps working when your laptop is closed, and you can
attach from your phone.

---

## Install

Requirements: macOS, [iTerm2](https://iterm2.com), Claude Code, `jq`, Python 3.

```bash
git clone https://github.com/Tomi2k/claude-handoff.git
mkdir -p ~/.claude/skills
cp -r claude-handoff/skills/handoff ~/.claude/skills/
```

**Context watcher hook** (recommended) - add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/skills/handoff/hooks/context_watcher.py 2>/dev/null || true",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

**Auto-close** (optional) - needs the iTerm2 Python API:

1. Enable iTerm2 > Settings > General > Magic > *Enable Python API*.
2. Install the module: `python3 -m pip install iterm2`
   (or point `HANDOFF_ITERM2_PYTHON` to a Python that has it).

Without it, everything works; the skill tells you to close the tab yourself.

The first launch asks macOS to let your terminal control iTerm2 (Automation). Allow it.

## Use

```
/handoff <goal in your own words>
/handoff remote <goal>
```

No goal? The skill asks one question: *What should the new session achieve?* It never
invents the goal. With the hook installed, Claude suggests the handoff by itself when the
threshold is reached - and still finishes the running step first.

## Configure

| Variable | Default | Effect |
|---|---|---|
| `HANDOFF_WATCH_AT` | `0.5` | Fraction of the window that triggers the suggestion. |
| `HANDOFF_WATCH_TOKENS` | - | Absolute trigger, whichever comes first. `150000` follows the smart-zone advice on 1M windows. |
| `CLAUDE_CONTEXT_WINDOW` | `200000` (`1000000` if the model has `[1m]`) | Window size used for the percentages. |
| `HANDOFF_DIR` | `~/.claude/handoffs` | Where handover files and small state files go. |
| `HANDOFF_MODEL` | - | Model alias for the new session, e.g. `opus`. |
| `HANDOFF_SKIP_PERMISSIONS` | `0` | `1` starts the new session with `--dangerously-skip-permissions`. Read *Security* first. |
| `HANDOFF_ITERM2_PYTHON` | `python3` | Python with the `iterm2` module, for auto-close. |
| `HANDOFF_REMOTE_HOST` | - | SSH alias for remote mode. On the server: `~/handoffs` and `~/projects/<repo>`. |

## What is in the box

```
skills/handoff/
├── SKILL.md                  the instructions Claude follows
├── hooks/context_watcher.py  UserPromptSubmit hook + `--status` for the skill
└── scripts/
    ├── handoff_launch.sh     new iTerm2 tab, start Claude Code, type /rename
    ├── handoff_title.sh      read the current name, build "... - Part N"
    ├── bg_check.sh           list background shells of the session
    └── autoclose.py          close the old tab once the session is idle
```

The rule behind the split: the skill file says *what to do and what to avoid*; everything
mechanical is a script, so the model runs one command instead of improvising.

## Security

I audited both the skill and the scripts before publishing. What you should know:

- **Bypass mode is opt-in.** `HANDOFF_SKIP_PERMISSIONS=1` starts the new session without
  permission prompts. Only use it if you understand what an agent can do on your machine
  without asking - including after reading untrusted web pages or files.
- **No command injection through names or paths.** Values reach AppleScript only as
  arguments, and the start command is a one-shot temp script quoted with `printf %q`.
  Tested with a path containing spaces and `'`, and a session name with `"`, `'`, `&`, `$`.
- **Auto-close is conservative.** It closes only the tab whose tty belongs to the session
  (if that is the window's last tab, iTerm2 closes the window with it), and aborts if the
  session becomes active again or shells still run.
- **Handover files are local** (`~/.claude/handoffs`). The skill forbids secrets in them,
  but a model can make mistakes - do not sync that folder anywhere public.
- **The new session treats the handover as notes, not as permission.** CONFIRM is the
  default; CONTINUE only covers work you assigned, quoted with date.
- **Remote mode never trusts a repository for you.** If Claude Code asks whether to trust
  a freshly cloned repository on the server, the skill stops and lets you decide: trusting
  it lets the repository's hooks and MCP settings run code.
- **Handover files stay private.** The folder is created with mode 700.
- **Background check output is redacted.** Values after `token=`, `key=`, `password=`,
  `Bearer` and `-p` are masked before they reach the model.
- **No network calls** except your own SSH in remote mode. No telemetry.

## Limits

- Tested on macOS 26.6, iTerm2 3.7.9 and Claude Code 2.1.330 (November 2026).
- The scripts read internal Claude Code files (`~/.claude/sessions/*.json`, transcripts in
  `~/.claude/projects/`). A Claude Code update can change them.
- "Does the rest fit into 10 %?" is the model's own estimate.
- `bg_check.sh` sees shells, not in-process background agents; the skill tracks those itself.
- Local mode needs iTerm2. Other terminals get the handover and the closing line, but no
  new tab, rename or auto-close.
- Remote mode is written as instructions for the model, not as a tested script. Local
  mode, rename and auto-close are tested end to end.

## License

MIT - see [LICENSE](LICENSE).

---

Built by **Timothy Scherman**. Less AI theater. More results.
