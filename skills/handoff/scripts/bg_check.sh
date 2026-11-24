#!/usr/bin/env bash
# Lists background shells that are still running in your own agent session.
# Works for Claude Code, Codex, agy and Grok; the CLI is found via the process tree.
#   claude: every Bash tool shell (also run_in_background and Monitor) is a direct child of
#           the claude process: "/bin/zsh -c source ~/.claude/shell-snapshots/... eval '<cmd>' ...".
#   others: every direct child of the CLI that is a shell (zsh, bash, sh, dash, fish), a
#           sandbox wrapper (sandbox-exec) or that runs in its own terminal (agy starts
#           commands directly in a new pty).
# MCP servers (started without a shell), caffeinate and the shell running this check are
# ignored. Background agents and workflows inside the CLI process are NOT visible here.
# A process on the terminal of the CLI whose parent has ended (parent pid 1) counts too.
# Limit: a program that Codex, agy or Grok starts directly on the terminal of the CLI,
# without a shell, looks like an MCP server and is not counted.
#
# usage: bg_check.sh [SESSION_ID | --pid PID]
#        no argument: your own CLI; SESSION_ID: a Claude Code session; --pid: that CLI process
# exit:  0 = no background shell, 1 = at least one is running,
#        2 = unknown: CLI process not found, or its children could not be listed (never
#            treat 2 as "nothing runs")
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPID=""; CLI=""
if [ "${1:-}" = "--pid" ]; then
  [[ "${2:-}" =~ ^[1-9][0-9]{0,6}$ ]] && [ "$2" -gt 1 ] && kill -0 "$2" 2>/dev/null && CPID="$2"
elif [ -n "${1:-}" ]; then
  [[ "$1" =~ ^[0-9A-Za-z_-]{8,64}$ ]] || { echo "ERROR: unexpected session id." >&2; exit 2; }
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    p=$(jq -r --arg s "$1" 'select(.sessionId == $s) | .pid' "$f" 2>/dev/null)
    if [[ "$p" =~ ^[1-9][0-9]{0,6}$ ]] && [ "$p" -gt 1 ] && kill -0 "$p" 2>/dev/null; then CPID="$p"; break; fi
  done
fi
if [ -z "${1:-}" ]; then
  CPID=$(python3 -I "$HERE/phself.py" 2>/dev/null | cut -f2)
fi
if [ -z "$CPID" ]; then
  echo "ERROR: agent CLI process not found (check the session id)." >&2
  exit 2
fi
CLI=$(ps -o comm= -p "$CPID" 2>/dev/null); CLI="${CLI##*/}"
CTTY=$(ps -o tty= -p "$CPID" 2>/dev/null | tr -d ' ')
case "$CLI" in claude|codex|agy|grok) ;; *) echo "ERROR: pid $CPID is not claude, codex, agy or grok." >&2; exit 2 ;; esac
# Our own call chain (this script and its parents) never counts.
ANC=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
  p=$(ps -o ppid= -p "$p" | tr -d ' ')
  [ -n "$p" ] || break
  ANC="$ANC$p "
done

# 2. Inspect the children of the claude process.
# First descendant command that is not a tool or wrapper shell (max 4 levels).
desc() {
  local k d=0 q="$1"
  while [ $d -lt 4 ] && [ -n "$q" ]; do
    local next=""
    for k in $q; do
      local kc kn; kc=$(ps -ww -o command= -p "$k" 2>/dev/null)
      kn=$(ps -o comm= -p "$k" 2>/dev/null); kn="${kn##*/}"; kn="${kn#-}"
      case "$kn" in zsh|bash|sh|dash|fish) kc="" ;; esac   # wrapper shells are not the work itself
      case "$kc" in ""|*shell-snapshots/snapshot-*) ;; *) [ "$d" -gt 0 ] && { printf '%s\n' "$kc"; return; } ;; esac
      next="$next $(pgrep -P "$k" | tr '\n' ' ')"
    done
    q="$next"; d=$((d + 1))
  done
}

# Mask secrets before the command line reaches the model: URL credentials, known token
# prefixes, Bearer/Basic values, JSON keys, --token/--password values (also quoted), the
# whole value after -H, --header, --cookie, -b, -u, --user and -a (up to the next option),
# -p values and KEY=/TOKEN= assignments. Over-masking is accepted.
redact() {
  python3 -I -c '
import re, sys
s = sys.stdin.read().replace("\n", " ")
rules = [
    (r"(://)[^/\s]+@", r"\1***@"),
    (r"(?<![A-Za-z0-9])(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{10,}|github_pat_\w{10,}"
     r"|xox[abprs]-[A-Za-z0-9-]{8,}|glpat-[\w-]{10,}|AKIA[0-9A-Z]{16}|AIza[\w-]{20,})", "***"),
    (r"((?:Bearer|Basic|Token)\s+)[^\s\"\x27]+", r"\1***"),
    # ps shows no quotes, so a header, cookie or user value can be several words long:
    # everything up to the next option (or the end) is masked.
    (r"((?<![\w-])(?:-H|--header|--cookie(?:-jar)?|-b|-u|--user|-a)(?:=|\s+))(.*?)(?=\s+--?[A-Za-z]|$)", r"\1***"),
    (r"((?:set-)?cookie\s*[:=]\s*)[^\"\x27]+", r"\1***"),
    (r"(\"[\w-]*(?:token|key|secret|passw(?:or)?d|auth)[\w-]*\"\s*:\s*)\"[^\"]*\"", r"\1***"),
    (r"(--?(?:token|password|passwd|pass|secret|key|api-key|apikey|auth|user)[=\s]+)"
     r"(\"[^\"]*\"|\x27[^\x27]*\x27|\S+)", r"\1***"),
    (r"(-u\s*)(\"[^\"]*\"|\x27[^\x27]*\x27|[^\s:]+:\S+)", r"\1***"),
    (r"(?<![\w-])(-p)\S{3,}", r"\1***"),
    (r"(?<![\w-])(-p\s+)[^\s-]\S*", r"\1***"),
    (r"(\w*(?:token|key|secret|passw(?:or)?d|auth)\w*[=:]\s*)(\"[^\"]*\"|\x27[^\x27]*\x27|[^*\s]\S*)", r"\1***"),
]
for pat, rep in rules:
    s = re.sub(pat, rep, s, flags=re.I)
print(s[:160])'
}

N=0
# pgrep: 0 = children found, 1 = none. Anything else is a failed listing, and a failed
# listing must never read as "nothing runs".
KIDS=$(pgrep -P "$CPID"); RC=$?
if [ "$RC" -gt 1 ]; then
  echo "ERROR: could not list the child processes of $CLI pid $CPID (pgrep exit $RC)." >&2
  exit 2
fi
for c in $KIDS; do
  case "$ANC" in *" $c "*) continue ;; esac          # our own call chain
  cmd=$(ps -ww -o command= -p "$c" 2>/dev/null) || continue
  inner=""
  if [ "$CLI" = "claude" ]; then
    case "$cmd" in
      *shell-snapshots/snapshot-*)
        inner=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -n "s/.* eval '\(.*\)' < \/dev\/null.*/\1/p" \
          | sed -e "s/'\"'\"'/'/g" -e "s/'\\\\''/'/g") ;;
      *) # a shell in an unknown layout (a Claude Code update?) counts as running work
        cn=$(ps -o comm= -p "$c" 2>/dev/null); cn="${cn##*/}"; cn="${cn#-}"
        case "$cn" in
          zsh|bash|sh|dash|fish) inner="(shell, unknown layout) $(desc "$c" | head -1)" ;;
          sandbox-exec) inner="(sandboxed command) $(desc "$c" | head -1)" ;;
          *) continue ;;
        esac ;;
    esac
  else
    # A tool process is a shell, a sandbox wrapper (Codex runs commands through
    # sandbox-exec on macOS), or runs in its own terminal (agy starts commands directly
    # in a new pty). MCP servers share the CLI's terminal and are not shells: they never count.
    cn=$(ps -o comm= -p "$c" 2>/dev/null); cn="${cn##*/}"; cn="${cn#-}"
    ct=$(ps -o tty= -p "$c" 2>/dev/null | tr -d ' ')
    case "$cn" in
      zsh|bash|sh|dash|fish|sandbox-exec) ;;
      *) if [ -z "$ct" ] || [ "$ct" = "??" ] || [ "$ct" = "$CTTY" ]; then continue; fi ;;
    esac
    inner=$(desc "$c" | head -1)   # the first non-shell process below it, e.g. "sleep 240"
    [ -n "$inner" ] || inner=$(printf '%s' "$cmd" | sed -E 's/^[^ ]*(zsh|bash|sh|dash|fish) +(-[a-z]+ +)*//')
  fi
  if [ -z "$inner" ]; then    # ps cut a very long command: show the real child process
    inner=$(desc "$c" | head -1)
    [ -n "$inner" ] || inner="$cmd"
  fi
  et=$(ps -o etime= -p "$c" | tr -d ' ')
  N=$((N + 1))
  shown=$(printf '%s' "$inner" | redact)
  printf 'RUNNING  pid %-6s for %-9s %s\n' "$c" "$et" "$shown"
done

# Detached work: a process on the terminal of the CLI whose parent has ended (parent pid 1),
# for example a command started with "nohup ... &". It dies when the tab closes.
if [ -n "$CTTY" ] && [ "$CTTY" != "??" ]; then
  for c in $(ps -t "$CTTY" -o pid=,ppid= 2>/dev/null | awk '$2 == 1 {print $1}'); do
    [ "$c" = "$CPID" ] && continue
    case "$ANC" in *" $c "*) continue ;; esac
    cmd=$(ps -ww -o command= -p "$c" 2>/dev/null) || continue
    [ -n "$cmd" ] || continue
    et=$(ps -o etime= -p "$c" | tr -d ' ')
    N=$((N + 1))
    printf 'RUNNING  pid %-6s for %-9s (detached) %s\n' "$c" "$et" "$(printf '%s' "$cmd" | redact)"
  done
fi

if [ "$N" -eq 0 ]; then
  echo "NO background shell running ($CLI pid $CPID)."
  exit 0
fi
echo "$N background shell(s) running ($CLI pid $CPID)."
exit 1
