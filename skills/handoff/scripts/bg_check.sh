#!/usr/bin/env bash
# Lists background shells that are still running in your own Claude Code session.
# Claude Code starts every Bash tool shell (also run_in_background and Monitor) as a
# direct child of the claude process: "/bin/zsh -c source ~/.claude/shell-snapshots/... eval '<cmd>' ...".
# MCP servers, caffeinate and the shell running this check are ignored.
# Background agents and workflows run inside the claude process and are NOT visible here.
#
# usage: bg_check.sh [SESSION_ID]
# exit:  0 = no background shell, 1 = at least one is running, 2 = claude process not found
set -uo pipefail
SID="${1:-}"

# 1. Find the claude PID: session registry first, then walk up the parent chain.
CPID=""
if [ -n "$SID" ]; then
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    p=$(jq -r --arg s "$SID" 'select(.sessionId == $s) | .pid' "$f" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then CPID="$p"; break; fi
  done
fi
ANC=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
  p=$(ps -o ppid= -p "$p" | tr -d ' ')
  [ -n "$p" ] || break
  ANC="$ANC$p "
  if [ -z "$CPID" ]; then
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$(basename "$comm")" in claude) CPID="$p" ;; esac
  fi
done
if [ -z "$CPID" ]; then
  echo "ERROR: claude process not found (check the session id)." >&2
  exit 2
fi

# 2. Inspect the children of the claude process.
# First descendant command that is not a Claude Code tool shell (max 4 levels).
desc() {
  local k d=0 q="$1"
  while [ $d -lt 4 ] && [ -n "$q" ]; do
    local next=""
    for k in $q; do
      local kc; kc=$(ps -ww -o command= -p "$k" 2>/dev/null)
      case "$kc" in ""|*shell-snapshots/snapshot-*) ;; *) [ "$d" -gt 0 ] && { printf '%s\n' "$kc"; return; } ;; esac
      next="$next $(pgrep -P "$k" | tr '\n' ' ')"
    done
    q="$next"; d=$((d + 1))
  done
}

N=0
for c in $(pgrep -P "$CPID"); do
  case "$ANC" in *" $c "*) continue ;; esac          # our own call chain
  cmd=$(ps -ww -o command= -p "$c" 2>/dev/null) || continue
  case "$cmd" in *shell-snapshots/snapshot-*) ;; *) continue ;; esac
  inner=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -n "s/.* eval '\(.*\)' < \/dev\/null.*/\1/p" \
    | sed -e "s/'\"'\"'/'/g" -e "s/'\\\\''/'/g")
  if [ -z "$inner" ]; then    # ps cut a very long command: show the real child process
    inner=$(desc "$c" | head -1)
    [ -n "$inner" ] || inner="$cmd"
  fi
  et=$(ps -o etime= -p "$c" | tr -d ' ')
  N=$((N + 1))
  shown=$(printf '%s' "$inner" | tr '\n' ' ' | sed -E \
    -e 's/((token|key|secret|passw(or)?d|auth)[A-Za-z_]*[=:][[:space:]]*)[^[:space:]]+/\1***/Ig' \
    -e 's/(Bearer[[:space:]]+)[^[:space:]]+/\1***/g' -e 's/(-p|--password)[[:space:]]+[^[:space:]]+/\1 ***/g' | cut -c1-160)
  printf 'RUNNING  pid %-6s for %-9s %s\n' "$c" "$et" "$shown"
done

if [ "$N" -eq 0 ]; then
  echo "NO background shell running (claude pid $CPID)."
  exit 0
fi
echo "$N background shell(s) running (claude pid $CPID)."
exit 1
