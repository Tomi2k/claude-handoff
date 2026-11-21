#!/usr/bin/env bash
# Opens a new tab in the current iTerm2 window, starts Claude Code there with the
# handover file, and (optionally) types "/rename <name>" into exactly that tab once
# the new session is up.
#
# usage: handoff_launch.sh <project_dir> <handover_file> [new_session_name]
# env:   HANDOFF_MODEL=<alias>       optional model for the new session (e.g. opus)
#        HANDOFF_SKIP_PERMISSIONS=1  start with --dangerously-skip-permissions (opt-in)
#
# Safety: values reach AppleScript only as arguments (never spliced into script source),
# and the start command is written to a one-shot temp script quoted with printf %q.
# Paths, prompt and session name therefore cannot inject shell or AppleScript commands.
set -uo pipefail
CWD="${1:-}"; HO="${2:-}"; NAME="${3:-}"
case "$NAME" in *[[:cntrl:]]*) echo "ERROR: session name contains control characters" >&2; exit 2 ;; esac
# Allowlist: letters, digits, space and . , _ + : - (en/em dash). No glob, quote or shell
# characters survive, so the text is harmless even if it ever lands on a shell prompt.
NAME=$(python3 -c 'import re,sys; s=re.sub(r"[^\w .,+:\u2013\u2014-]", "", sys.argv[1]); print(s.lstrip("-. ").strip()[:80])' "$NAME") \
  || { echo "ERROR: python3 is needed to check the session name" >&2; exit 2; }
[ -d "$CWD" ] || { echo "ERROR: project dir not found: $CWD" >&2; exit 2; }
[ -f "$HO" ]  || { echo "ERROR: handover file not found: $HO" >&2; exit 2; }
LAUNCH_MS=$(( $(date +%s) * 1000 ))

PROMPT="Read $HO completely first. Do not reopen decisions that are already made. Follow the Mode section exactly. In CONTINUE mode, first check that the open assigned work is really still open. If it is, continue ONLY that work until its Done-when criterion is met, then report and stop. If it is already done, behave as in CONFIRM mode. In CONFIRM mode, or if the Mode section is missing, do NOT start working: summarise goal, context and state in a few sentences, name the first item under Assigned and ask: Do you want me to do <step> next? If Assigned is empty, say: The assignment is done. Then offer the Suggestions as options and wait. Never invent follow-up tasks. Never run Suggestions without approval."

ARGS=()
[ "${HANDOFF_SKIP_PERMISSIONS:-0}" = "1" ] && ARGS+=(--dangerously-skip-permissions)
if [ -n "${HANDOFF_MODEL:-}" ]; then
  if [[ "$HANDOFF_MODEL" =~ ^[A-Za-z0-9._-]{2,40}$ ]]; then ARGS+=(--model "$HANDOFF_MODEL")
  else echo "WARNING: HANDOFF_MODEL ignored (unexpected characters)" >&2; fi
fi

# The start command goes into a one-shot script that bash parses (printf %q quoting).
# Only "bash '<tmpfile>'" is typed into the new tab: interactive zsh line editing
# (quote and paste widgets) can mangle long escaped command lines.
TMP=$(mktemp "${TMPDIR:-/tmp}/handoff-launch.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
[[ "$TMP" =~ ^[A-Za-z0-9/._+-]+$ ]] || { rm -f -- "$TMP"; echo "ERROR: unexpected temp path" >&2; exit 1; }
{
  echo '#!/usr/bin/env bash'
  echo 'rm -f -- "$0"'
  printf 'cd -- %q || exit 1\n' "$CWD"
  printf 'exec claude'
  for a in ${ARGS[@]+"${ARGS[@]}"}; do printf ' %q' "$a"; done
  printf ' %q\n' "$PROMPT"
} > "$TMP"
chmod 700 "$TMP"

OUT=$(osascript - "bash '$TMP'" <<'EOF'
on run argv
  set theCommand to item 1 of argv
  tell application "iTerm"
    if (count of windows) = 0 then
      create window with default profile
    else
      tell current window to create tab with default profile
    end if
    tell current session of current window
      write text theCommand
      return (id as text) & "|" & (tty as text)
    end tell
  end tell
end run
EOF
) || { rm -f -- "$TMP"; echo "ERROR: could not open an iTerm2 tab (is iTerm2 running and allowed to be automated?)" >&2; exit 1; }
ITERM_SID="${OUT%%|*}"; TAB_TTY="${OUT#*|}"
echo "iTerm2 tab started (session $ITERM_SID, $TAB_TTY)"
[ -z "$NAME" ] && exit 0

# Wait until the new Claude Code session shows up in the session registry (max 90 s).
# Match it by the tty of the new tab: other sessions may start in the same folder
# at the same time. Note: ~/.claude/sessions/*.json is internal and may change.
READY=""
for _ in $(seq 1 90); do
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    pid=$(jq -r --argjson t "$LAUNCH_MS" 'select(.startedAt > $t) | .pid' "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    if [ "/dev/$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')" = "$TAB_TTY" ]; then
      READY=$(jq -r .sessionId "$f"); CPID="$pid"; break 2
    fi
  done
  sleep 1
done
rm -f -- "$TMP"   # normally already removed by the script itself
if [ -z "$READY" ]; then
  echo "WARNING: new session not found - skipped /rename (run it once by hand)" >&2
  exit 1
fi
sleep 4  # let the TUI finish drawing

# AppleScript helper for exactly that tab (the user may have switched tabs meanwhile).
# $1 = "screen" (print the visible text), "text" (type $2 without newline) or "cr" (Enter).
tab() {
  osascript - "$ITERM_SID" "$1" "${2:-}" <<'EOF'
on run argv
  set targetId to item 1 of argv
  tell application "iTerm"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is targetId then
            if item 2 of argv is "screen" then return contents of s
            if item 2 of argv is "cr" then
              tell s to write text (ASCII character 13) newline NO
            else
              tell s to write text (item 3 of argv) newline NO
            end if
            return "found"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "missing"
end run
EOF
}
# claude must still run in the foreground of the tab - never type into a plain shell.
fg_ok() { kill -0 "$CPID" 2>/dev/null && ps -t "${TAB_TTY#/dev/}" -o stat=,pid= | awk -v p="$CPID" '$2==p && $1 ~ /\+/ {f=1} END {exit !f}'; }
# The screen must show Claude Code's input box (a line of box characters, then the prompt
# line) and no numbered choice: trust, MCP and permission dialogs show "❯ 1. ...".
# $1 = what the input line must hold: "" (empty) or "/rename" (our typed text).
input_is() {
  tab screen | python3 -c '
import re, sys
want = sys.argv[1]
lines = sys.stdin.read().splitlines()[-40:]
if any(re.search(r"❯\s*\d+[.)]", l) or re.match(r"\s*[│|]?\s*>\s*\d+[.)]\s", l) for l in lines):
    sys.exit(1)
for above, line in reversed(list(zip(lines, lines[1:]))):  # the input box is the lowest one
    t = line.strip()
    if re.match(r"\s*[─━]{20,}", above) and t[:1] in ("❯", ">"):
        rest = t[1:].strip()
        sys.exit(0 if (rest == "" if want == "" else rest.startswith(want + " ")) else 1)
sys.exit(1)' "$1"
}

if ! fg_ok; then echo "WARNING: claude is not in the foreground of the new tab - skipped /rename" >&2; exit 1; fi
if ! input_is ""; then
  echo "WARNING: the new tab does not show an empty Claude Code input box (dialog open?) - skipped /rename. Run /rename once by hand." >&2
  exit 1
fi
# Two steps: type the text, check screen and foreground again, then press Enter.
# A plain newline only adds a line break in Claude Code's input box, so Enter is a real CR.
R=$(tab text "/rename $NAME")
sleep 1.5
if [ "$R" != "found" ]; then echo "WARNING: tab of the new session is gone - skipped /rename" >&2; exit 1; fi
if ! fg_ok || ! input_is "/rename"; then
  echo "WARNING: typed text is not in Claude Code's input box - did NOT press Enter. Check the new tab." >&2
  exit 1
fi
R=$(tab cr)
if [ "$R" = "found" ]; then echo "Session $READY renamed: $NAME"
else echo "WARNING: tab of the new session is gone - skipped /rename" >&2; exit 1; fi
