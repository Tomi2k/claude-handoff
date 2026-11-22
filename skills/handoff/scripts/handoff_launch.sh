#!/usr/bin/env bash
# Opens a new tab in the current iTerm2 window, starts an agent CLI there with the
# handover file, and gives the new session its name.
#
# usage: handoff_launch.sh [--to claude|codex|agy|grok] <project_dir> <handover_file> [--name <name> | --no-name]
#        --to defaults to claude. Any CLI can hand off to any other one.
#        Name: by default the launcher reads the name of YOUR session itself
#        (handoff_title.sh current) and gives the new one "<name> - Part N". The agent never
#        handles the name in a command line. --name only for a name the user dictated.
# env:   HANDOFF_MODEL=<name>        optional model for the new session
#        HANDOFF_SKIP_PERMISSIONS=1  start without permission prompts (opt-in, user only):
#          claude/agy --dangerously-skip-permissions, codex --dangerously-bypass-approvals-and-sandbox,
#          grok --always-approve
#        HANDOFF_ITERM2_PYTHON       Python with the iterm2 module (tab titles), default python3
#
# Name: Claude Code gets a real "/rename <name>", typed only into an empty Claude Code input
# box. Codex, agy and Grok get the iTerm2 tab title instead (nothing is typed into them).
#
# Safety: values reach AppleScript only as arguments (never spliced into script source),
# and the start command is written to a one-shot temp script quoted with printf %q.
# Paths, prompt and session name therefore cannot inject shell or AppleScript commands.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TO=claude
if [ "${1:-}" = "--to" ]; then TO="${2:-}"; shift 2 || true; fi
case "$TO" in claude|codex|agy|grok) ;; *) echo "ERROR: --to must be claude, codex, agy or grok" >&2; exit 2 ;; esac
command -v "$TO" >/dev/null 2>&1 || { echo "ERROR: $TO is not installed (not in PATH)" >&2; exit 2; }
CWD="${1:-}"; HO="${2:-}"
case "${3:-}" in
  "") INFO=$("$HERE/handoff_title.sh" current 2>/dev/null || true)
      NAME=$("$HERE/handoff_title.sh" next "${INFO%|*}" 2>/dev/null || true) ;;
  --no-name) NAME="" ;;
  --name) NAME="${4:-}" ;;
  *) echo "ERROR: third argument must be --name <name> or --no-name" >&2; exit 2 ;;
esac
case "$NAME" in *[[:cntrl:]]*) echo "ERROR: session name contains control characters" >&2; exit 2 ;; esac
# Allowlist: letters, digits, space and . , _ + : - (en/em dash). No glob, quote or shell
# characters survive, so the text is harmless even if it ever lands on a shell prompt.
NAME=$(python3 -c 'import re,sys; s=re.sub(r"[^\w .,+:–—-]", "", sys.argv[1]); print(s.lstrip("-. ").strip()[:80])' "$NAME") \
  || { echo "ERROR: python3 is needed to check the session name" >&2; exit 2; }
[ -d "$CWD" ] || { echo "ERROR: project dir not found: $CWD" >&2; exit 2; }
[ -f "$HO" ]  || { echo "ERROR: handover file not found: $HO" >&2; exit 2; }
LAUNCH_MS=$(( $(date +%s) * 1000 ))

PROMPT="Read $HO completely first. Do not reopen decisions that are already made. Follow the Mode section exactly. In CONTINUE mode, first check that the open assigned work is really still open. If it is, continue ONLY that work until its Done-when criterion is met, then report and stop. If it is already done, behave as in CONFIRM mode. In CONFIRM mode, or if the Mode section is missing, do NOT start working: summarise goal, context and state in a few sentences, name the first item under Assigned and ask: Do you want me to do <step> next? If Assigned is empty, say: The assignment is done. Then offer the Suggestions as options and wait. Never invent follow-up tasks. Never run Suggestions without approval."

ARGS=()
if [ "${HANDOFF_SKIP_PERMISSIONS:-0}" = "1" ]; then
  case "$TO" in
    claude|agy) ARGS+=(--dangerously-skip-permissions) ;;
    codex) ARGS+=(--dangerously-bypass-approvals-and-sandbox) ;;
    grok) ARGS+=(--always-approve) ;;
  esac
fi
if [ -n "${HANDOFF_MODEL:-}" ]; then
  if [[ "$HANDOFF_MODEL" =~ ^[A-Za-z0-9._-]{2,40}$ ]]; then ARGS+=(--model "$HANDOFF_MODEL")
  else echo "WARNING: HANDOFF_MODEL ignored (unexpected characters)" >&2; fi
fi
[ "$TO" = "agy" ] && ARGS+=(-i)   # agy: run the prompt interactively and keep the session

# The start command goes into a one-shot script that bash parses (printf %q quoting).
# Only "bash '<tmpfile>'" is typed into the new tab: interactive zsh line editing
# (quote and paste widgets) can mangle long escaped command lines.
TMP=$(mktemp "${TMPDIR:-/tmp}/handoff-launch.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
[[ "$TMP" =~ ^[A-Za-z0-9/._+-]+$ ]] || { rm -f -- "$TMP"; echo "ERROR: unexpected temp path" >&2; exit 1; }
{
  echo '#!/usr/bin/env bash'
  echo 'rm -f -- "$0"'
  printf 'cd -- %q || exit 1\n' "$CWD"
  printf 'exec %q' "$TO"
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
echo "iTerm2 tab started ($TO, session $ITERM_SID, $TAB_TTY)"
[[ "$TAB_TTY" =~ ^/dev/ttys?[0-9]{1,4}$ ]] || { echo "WARNING: unexpected tty '$TAB_TTY' - no name set" >&2; exit 1; }
[ -z "$NAME" ] && exit 0

# Wait until the CLI runs in the foreground of the new tab (max 60 s). Matching by the
# tab's tty is safe with other sessions starting in the same folder at the same time.
fg_pid() { ps -t "${TAB_TTY#/dev/}" -o stat=,pid=,comm= 2>/dev/null \
  | awk -v c="$TO" '$1 ~ /\+/ { n = split($3, p, "/"); if (p[n] == c) { print $2; exit } }'; }
CPID=""
for _ in $(seq 1 60); do CPID=$(fg_pid); [ -n "$CPID" ] && break; sleep 1; done
[ -z "$CPID" ] && { rm -f -- "$TMP"; echo "WARNING: $TO did not start in the new tab - no name set" >&2; exit 1; }

if [ "$TO" != "claude" ]; then
  # Codex, agy, Grok: the name is the tab title. Nothing is typed into the session.
  R=$(python3 "$HERE/tabtitle.py" set "$TAB_TTY" "$NAME" 2>&1)
  if [ $? -eq 0 ]; then echo "Tab title set: $R"; exit 0; fi
  # Without the iterm2 module: AppleScript session name (a CLI's own title may replace it).
  osascript - "$ITERM_SID" "$NAME" <<'EOF' >/dev/null && { echo "Session name set (AppleScript): $NAME"; exit 0; }
on run argv
  tell application "iTerm"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is (item 1 of argv) then
            set name of s to (item 2 of argv)
            return "found"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "missing"
end run
EOF
  echo "WARNING: could not name the new tab ($R)" >&2; exit 1
fi

# Claude Code: wait until the new session shows up in the session registry (max 90 s).
# Note: ~/.claude/sessions/*.json is internal and may change.
READY=""
for _ in $(seq 1 90); do
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    pid=$(jq -r --argjson t "$LAUNCH_MS" 'select(.startedAt > $t) | .pid' "$f" 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" = "$CPID" ]; then READY=$(jq -r .sessionId "$f"); break 2; fi
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
              -- last check in the same call: our text is still in the input box, no choice menu
              set c to contents of s
              -- Claude Code puts a no-break space (character id 160) after the prompt glyph
              set nb to character id 160
              if c does not contain (item 3 of argv) or c contains "❯ 1." or c contains ("❯" & nb & "1.") then return "changed"
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
fg_ok() { kill -0 "$CPID" 2>/dev/null && [ "$(fg_pid)" = "$CPID" ]; }
# The screen must show Claude Code's input box (a line of box characters, then the prompt
# line) and no numbered choice: trust, MCP and permission dialogs show "❯ 1. ...".
# $1 = what the input line must hold: "" (empty) or "/rename" (our typed text).
input_is() {
  tab screen | python3 -c '
import re, sys
want = sys.argv[1]
lines = sys.stdin.read().splitlines()
while lines and not lines[-1].strip():  # a fresh session leaves empty rows at the bottom
    lines.pop()
lines = lines[-40:]
if any(re.search(r"[❯›]\s*\d+[.)]", l) or re.match(r"\s*[│|]?\s*>\s*\d+[.)]\s", l) for l in lines):
    sys.exit(1)
pairs = list(zip(lines, lines[1:]))[-15:]  # the input box sits near the bottom
for above, line in reversed(pairs):        # the lowest one is the input box
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
R=$(tab cr "/rename $NAME")
if [ "$R" = "found" ]; then echo "Session $READY renamed: $NAME"
elif [ "$R" = "changed" ]; then echo "WARNING: the screen changed before Enter - did NOT press Enter. Check the new tab." >&2; exit 1
else echo "WARNING: tab of the new session is gone - skipped /rename" >&2; exit 1; fi
