#!/usr/bin/env bash
# Carry the session name over to the next session.
#
#   handoff_title.sh current [<own_claude_session_id>]
#     -> prints "name|sessionId" of YOUR session (found via the process tree).
#        Claude Code: the LAST custom-title event in your own transcript (every /rename
#        appends one), so the name the user gave most recently wins; fallback: the
#        session registry. Codex, agy, Grok: the iTerm2 tab title of your own tab
#        (needs the iterm2 module: install.sh --iterm2 or HANDOFF_ITERM2_PYTHON).
#        Never guess by "latest session": parallel sessions in the same folder exist.
#   handoff_title.sh next "<old name>"
#     -> prints the follow-up name: "... - Part N" is incremented, otherwise
#        " - Part 2" is appended. Empty input gives empty output.
#
# Note: transcripts (~/.claude/projects/*/<id>.jsonl) and the registry
# (~/.claude/sessions/*.json) are internal Claude Code files and may change.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  current)
    own="${2:-}"
    if [ -z "$own" ]; then
      IFS=$'\t' read -r cli _pid tty sid < <(python3 "$HERE/phself.py") || { echo "ERROR: own CLI not found" >&2; exit 2; }
      if [ "$cli" != "claude" ]; then
        [ "$tty" = "-" ] && exit 0
        name=$(python3 "$HERE/tabtitle.py" get "$tty" 2>/dev/null || true)
        case "$name" in MANUAL:*|"") exit 0 ;; esac
        echo "$name|$sid"; exit 0
      fi
      own="$sid"
    fi
    [[ "$own" =~ ^[0-9A-Za-z_-]{8,64}$ ]] || { echo "usage: handoff_title.sh current [<own_session_id>]" >&2; exit 2; }
    for tr in "$HOME"/.claude/projects/*/"$own".jsonl; do
      [ -r "$tr" ] || continue
      last=$(grep -a '"custom-title"' "$tr" \
        | jq -r 'select(.type == "custom-title" and (.customTitle | type) == "string" and .customTitle != "") | .customTitle' 2>/dev/null \
        | tail -1 || true)
      if [ -n "$last" ]; then echo "$last|$own"; exit 0; fi
    done
    for f in "$HOME"/.claude/sessions/*.json; do
      [ -e "$f" ] || continue
      jq -r --arg sid "$own" \
        'select(.sessionId == $sid and .name != null) | "\(.name)|\(.sessionId)"' "$f" 2>/dev/null
    done | head -1
    ;;
  next)
    old="${2:-}"
    if [[ "$old" =~ ^(.*)\ -\ Part\ ([0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]} - Part $(( 10#${BASH_REMATCH[2]} + 1 ))"
    elif [ -n "$old" ]; then
      echo "$old - Part 2"
    fi
    ;;
  *) echo "usage: handoff_title.sh current <session_id> | next \"<name>\"" >&2; exit 2 ;;
esac
