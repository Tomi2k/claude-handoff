#!/usr/bin/env bash
# Lists background shells that are still running in your own agent session.
# Works for Claude Code, Codex, agy and Grok; the CLI is found via the process tree.
#   claude: every Bash tool shell (also run_in_background and Monitor) is a direct child of
#           the claude process: "/bin/zsh -c source ~/.claude/shell-snapshots/... eval '<cmd>' ...".
#   others: every direct child of the CLI that is a shell (zsh, bash, sh, dash, fish) or that
#           runs in its own terminal (agy starts commands directly in a new pty).
# MCP servers (started without a shell), caffeinate and the shell running this check are
# ignored. Background agents and workflows inside the CLI process are NOT visible here.
#
# usage: bg_check.sh [SESSION_ID | --pid PID]
#        no argument: your own CLI; SESSION_ID: a Claude Code session; --pid: that CLI process
# exit:  0 = no background shell, 1 = at least one is running, 2 = CLI process not found
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
if [ -z "$CPID" ] && [ "${1:-}" != "--pid" ]; then
  CPID=$(python3 "$HERE/phself.py" 2>/dev/null | cut -f2)
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
# prefixes, Bearer/Basic values, JSON keys, --token/--password/--user values (also quoted),
# -u user:pass, -p values and KEY=/TOKEN= assignments. Over-masking is accepted.
redact() {
  python3 -c '
import re, sys
s = sys.stdin.read().replace("\n", " ")
rules = [
    (r"(://)[^/\s]+@", r"\1***@"),
    (r"(?<![A-Za-z0-9])(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{10,}|github_pat_\w{10,}"
     r"|xox[abprs]-[A-Za-z0-9-]{8,}|glpat-[\w-]{10,}|AKIA[0-9A-Z]{16}|AIza[\w-]{20,})", "***"),
    (r"((?:Bearer|Basic|Token)\s+)[^\s\"\x27]+", r"\1***"),
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
for c in $(pgrep -P "$CPID"); do
  case "$ANC" in *" $c "*) continue ;; esac          # our own call chain
  cmd=$(ps -ww -o command= -p "$c" 2>/dev/null) || continue
  inner=""
  if [ "$CLI" = "claude" ]; then
    case "$cmd" in *shell-snapshots/snapshot-*) ;; *) continue ;; esac
    inner=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -n "s/.* eval '\(.*\)' < \/dev\/null.*/\1/p" \
      | sed -e "s/'\"'\"'/'/g" -e "s/'\\\\''/'/g")
  else
    # A tool process is a shell, or runs in its own terminal (agy starts commands directly
    # in a new pty). MCP servers share the CLI's terminal and are not shells: they never count.
    cn=$(ps -o comm= -p "$c" 2>/dev/null); cn="${cn##*/}"; cn="${cn#-}"
    ct=$(ps -o tty= -p "$c" 2>/dev/null | tr -d ' ')
    case "$cn" in
      zsh|bash|sh|dash|fish) ;;
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

if [ "$N" -eq 0 ]; then
  echo "NO background shell running ($CLI pid $CPID)."
  exit 0
fi
echo "$N background shell(s) running ($CLI pid $CPID)."
exit 1
