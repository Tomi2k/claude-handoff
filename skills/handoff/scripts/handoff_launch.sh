#!/usr/bin/env bash
# Opens a new tab next to YOUR session in iTerm2, starts an agent CLI there with the
# handover file, and gives the new session its name. Nothing is ever typed into the new
# session: the start command carries everything.
#
# usage: handoff_launch.sh [--to claude|codex|agy|grok] <project_dir> <handover_file> [--name - | --no-name]
#        --to       the CLI of the new session (default claude); any CLI can hand off to any other
#        (default)  the launcher reads the name of YOUR session itself (handoff_title.sh) and
#                   names the new one "<name> - Part N"
#        --name -   read a name the user dictated from stdin (one line, no shell quoting needed)
#        --no-name  no name
# exit:  0 = the new session runs (and is named)
#        1 = the new session runs, but the name is missing (WARNING)
#        2 = bad arguments
#        3 = the new session did NOT start - do not close the old session
# env:   HANDOFF_MODEL=<name>        optional model for the new session
#        HANDOFF_DIR=<dir>           handover folder (default ~/.claude/handoffs)
#        HANDOFF_SKIP_PERMISSIONS=1  start without permission prompts (opt-in, user only):
#          claude/agy --dangerously-skip-permissions, codex --dangerously-bypass-approvals-and-sandbox,
#          grok --always-approve. This one is NOT read here: the start script reads it in the
#          shell of the new tab (the user's own profile). A value that exists only in the
#          environment of the agent running this launcher has no effect.
#
# The handover file must be the user's own regular file directly in the handover folder
# (real absolute path, no symlink, mode 600 or stricter, name [A-Za-z0-9._-]+.md, at most
# 24 hours old; folder mode 700). The start script checks the folder again in the new tab
# against the user's own HANDOFF_DIR.
#
# Name: Claude Code gets it with --name at start. Codex, agy and Grok get the iTerm2 tab
# title (tabtitle.py). The tab opens in the window of YOUR session (found by its tty);
# without one (not started from iTerm2) a new iTerm2 window opens.
#
# Safety: values reach AppleScript only as arguments (never spliced into script source),
# and the start command is a one-shot temp script quoted with printf %q. Python runs with
# -I, so modules in the project folder are never imported.
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
  --name) [ "${4:-}" = "-" ] || { echo "ERROR: use --name - and pass the name on stdin" >&2; exit 2; }
          IFS= read -r NAME || true ;;
  *) echo "ERROR: third argument must be --name - or --no-name" >&2; exit 2 ;;
esac
case "$NAME" in *[[:cntrl:]]*) echo "ERROR: session name contains control characters" >&2; exit 2 ;; esac
# Allowlist: letters, digits, space and . , _ + : - (en/em dash). No glob, quote, backslash
# or shell character survives (iTerm2 would also interpolate \( ... ) in a tab title).
NAME=$(python3 -I -c 'import re,sys; s=re.sub(r"[^\w .,+:–—-]", "", sys.argv[1]); print(s.lstrip("-. ").strip()[:80])' "$NAME") \
  || { echo "ERROR: python3 is needed to check the session name" >&2; exit 2; }
[ -d "$CWD" ] || { echo "ERROR: project dir not found: $CWD" >&2; exit 2; }
# The new session is told to follow this file, so only the user's own handover file in the
# handover folder is accepted: never a symlink, a file of another user, a file that others
# can read or write, or a file somewhere in a project.
python3 -I -c '
import os, re, stat, sys, time
ho, d = sys.argv[1], os.path.expanduser(sys.argv[2])
def bad(msg):
    sys.stderr.write("ERROR: handover file: " + msg + "\n")
    sys.exit(1)
if not os.path.isabs(ho) or re.search(r"[\x00-\x1f\x7f]", ho):
    bad("pass an absolute path without control characters")
try:
    st = os.lstat(ho)
except OSError:
    bad("not found: " + ho)
if not stat.S_ISREG(st.st_mode):
    bad("not a regular file (symlinks are not followed): " + ho)
if st.st_uid != os.getuid():
    bad("not owned by you: " + ho)
if st.st_mode & 0o077:
    bad("others can read or write it - run chmod 600 on it: " + ho)
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.md", os.path.basename(ho)):
    bad("unexpected file name (letters, digits, . _ - and the ending .md)")
if ho != os.path.realpath(ho):
    bad("pass the real path (no symlink and no .. in any folder of the path)")
if os.path.dirname(ho) != os.path.realpath(d):
    bad("must be directly in the handover folder " + d)
ds = os.lstat(os.path.dirname(ho))
if not stat.S_ISDIR(ds.st_mode) or ds.st_uid != os.getuid() or ds.st_mode & 0o077:
    bad("the handover folder must be your own folder with mode 700")
if time.time() - st.st_mtime > 86400:
    bad("older than 24 hours - write a new handover file for this handoff")
' "$HO" "${HANDOFF_DIR:-$HOME/.claude/handoffs}" || exit 2

PROMPT="Read $HO completely first. Do not reopen decisions that are already made. Follow the Mode section exactly. In CONTINUE mode, first check that the open assigned work is really still open. If it is, continue ONLY that work until its Done-when criterion is met, then report and stop. If it is already done, behave as in CONFIRM mode. In CONFIRM mode, or if the Mode section is missing, do NOT start working: summarise goal, context and state in a few sentences, name the first item under Assigned and ask: Do you want me to do <step> next? If Assigned is empty, say: The assignment is done. Then offer the Suggestions as options and wait. Never invent follow-up tasks. Never run Suggestions without approval."

ARGS=()
# The bypass flag of the target CLI. Whether it is used is decided in the new tab (below).
case "$TO" in
  claude|agy) SKIPFLAG=--dangerously-skip-permissions ;;
  codex) SKIPFLAG=--dangerously-bypass-approvals-and-sandbox ;;
  grok) SKIPFLAG=--always-approve ;;
esac
if [ -n "${HANDOFF_MODEL:-}" ]; then
  if [[ "$HANDOFF_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,39}$ ]]; then ARGS+=(--model "$HANDOFF_MODEL")
  else echo "WARNING: HANDOFF_MODEL ignored (unexpected characters)" >&2; fi
fi
[ "$TO" = "claude" ] && [ -n "$NAME" ] && ARGS+=(--name "$NAME")
[ "$TO" = "agy" ] && ARGS+=(-i)   # agy: run the prompt interactively and keep the session

# The start command goes into a one-shot script that bash parses (printf %q quoting).
# Only "bash '<tmpfile>'" is typed into the new tab: interactive zsh line editing
# (quote and paste widgets) can mangle long escaped command lines.
TMP=$(mktemp "${TMPDIR:-/tmp}/handoff-launch.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 2; }
[[ "$TMP" =~ ^[A-Za-z0-9/._+-]+$ ]] || { rm -f -- "$TMP"; echo "ERROR: unexpected temp path" >&2; exit 2; }
{
  echo '#!/usr/bin/env bash'
  echo 'rm -f -- "$0"'
  # The handover folder is the user's own setting too. The launcher checked the file
  # against HANDOFF_DIR of ITS environment; the new tab checks the folder again against
  # the user's profile, so a folder that only an agent set is refused here.
  echo 'D="${HANDOFF_DIR:-$HOME/.claude/handoffs}"; D="${D/#\~/$HOME}"'
  printf 'if [ "$(cd -- "$D" 2>/dev/null && pwd -P)" != %q ]; then\n' "$(dirname "$HO")"
  echo '  echo "Perfect Handoff: the handover file is not in your handover folder ($D). Nothing was started."; exit 1'
  echo 'fi'
  printf 'cd -- %q || exit 1\n' "$CWD"
  # HANDOFF_SKIP_PERMISSIONS is the user's own setting. It is read here, in the shell of the
  # new tab, which iTerm2 starts from the user's profile - not from the environment of the
  # agent that runs this launcher, where an agent could put it in front of the command.
  printf 'S=(); [ "${HANDOFF_SKIP_PERMISSIONS:-0}" = "1" ] && S=(%q)\n' "$SKIPFLAG"
  printf 'exec %q ${S[@]+"${S[@]}"}' "$TO"
  for a in ${ARGS[@]+"${ARGS[@]}"}; do printf ' %q' "$a"; done
  printf ' %q\n' "$PROMPT"
} > "$TMP"
chmod 700 "$TMP"

# The new tab goes into the window that holds YOUR session (matched by tty), not into
# whatever window has the focus. The command goes to the session of exactly that new tab.
SRC_TTY=$(python3 -I "$HERE/phself.py" 2>/dev/null | cut -f3)
OUT=$(osascript - "bash '$TMP'" "${SRC_TTY:--}" <<'EOF'
on run argv
  set theCommand to item 1 of argv
  set srcTty to item 2 of argv
  tell application "iTerm"
    set winId to missing value
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (tty of s) is srcTty then set winId to (id of w)
        end repeat
      end repeat
    end repeat
    if winId is missing value then
      set newWindow to (create window with default profile)
      set newSession to current session of newWindow
    else
      tell (first window whose id is winId) to set newTab to (create tab with default profile)
      set newSession to current session of newTab
    end if
    tell newSession to write text theCommand
    return (id of newSession as text) & "|" & (tty of newSession as text)
  end tell
end run
EOF
) || { rm -f -- "$TMP"; echo "ERROR: could not open an iTerm2 tab (is iTerm2 running and allowed to be automated?)" >&2; exit 3; }
ITERM_SID="${OUT%%|*}"; TAB_TTY="${OUT#*|}"
[[ "$TAB_TTY" =~ ^/dev/ttys?[0-9]{1,4}$ ]] || { rm -f -- "$TMP"; echo "ERROR: unexpected tty '$TAB_TTY'" >&2; exit 3; }
echo "iTerm2 tab opened ($TO, session $ITERM_SID, $TAB_TTY)"

# The CLI must run in the foreground of the new tab (max 60 s), and still run 3 s later.
# Matching by the tab's tty is safe with other sessions starting in the same folder.
fg_pid() {
  local p c
  for p in $(ps -t "${TAB_TTY#/dev/}" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\+/ {print $1}'); do
    c=$(ps -o comm= -p "$p" 2>/dev/null); c="${c##*/}"
    [ "$c" = "$TO" ] && { echo "$p"; return; }
  done
}
CPID=""
for _ in $(seq 1 60); do CPID=$(fg_pid); [ -n "$CPID" ] && break; sleep 1; done
rm -f -- "$TMP"   # normally already removed by the script itself
if [ -z "$CPID" ]; then
  echo "ERROR: $TO did not start in the new tab. Do NOT close this session; tell the user." >&2; exit 3
fi
sleep 3
if [ "$(fg_pid)" != "$CPID" ]; then
  echo "ERROR: $TO stopped right after the start. Do NOT close this session; tell the user." >&2; exit 3
fi
echo "New session runs ($TO pid $CPID)."
[ -z "$NAME" ] && exit 0
if [ "$TO" = "claude" ]; then echo "Name: $NAME"; exit 0; fi

# Codex, agy, Grok: the name is the tab title. Nothing is typed into the session.
if R=$(python3 -I "$HERE/tabtitle.py" set "$TAB_TTY" "$NAME" 2>&1); then echo "Tab title: $R"; exit 0; fi
# Without the iterm2 module: AppleScript session name (a CLI's own title may replace it).
if osascript - "$ITERM_SID" "$NAME" >/dev/null 2>&1 <<'EOF'
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
then echo "Session name (AppleScript, may be replaced by the CLI's own title): $NAME"; exit 0; fi
echo "WARNING: could not name the new tab ($R)" >&2; exit 1
