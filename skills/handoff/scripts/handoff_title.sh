#!/usr/bin/env bash
# Carry the session name over to the next session.
#
#   handoff_title.sh current <own_session_id>
#     -> prints "name|sessionId" of YOUR session. Source of truth is the LAST
#        custom-title event in your own transcript (every /rename appends one), so the
#        name the user gave most recently wins. Fallback: the session registry.
#        Always pass your own session id: with parallel sessions in the same folder,
#        any "latest session" heuristic picks the wrong name.
#   handoff_title.sh next "<old name>"
#     -> prints the follow-up name: "... - Part N" is incremented, otherwise
#        " - Part 2" is appended. Empty input gives empty output.
#
# Note: transcripts (~/.claude/projects/*/<id>.jsonl) and the registry
# (~/.claude/sessions/*.json) are internal Claude Code files and may change.
set -euo pipefail

case "${1:-}" in
  current)
    own="${2:-}"
    [ -n "$own" ] || { echo "usage: handoff_title.sh current <own_session_id>" >&2; exit 2; }
    for tr in "$HOME"/.claude/projects/*/"$own".jsonl; do
      [ -r "$tr" ] || continue
      last=$(grep -a '"type":"custom-title"' "$tr" | tail -1 \
        | jq -r 'select(.customTitle != null and .customTitle != "") | .customTitle' 2>/dev/null || true)
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
      echo "${BASH_REMATCH[1]} - Part $(( BASH_REMATCH[2] + 1 ))"
    elif [ -n "$old" ]; then
      echo "$old - Part 2"
    fi
    ;;
  *) echo "usage: handoff_title.sh current <session_id> | next \"<name>\"" >&2; exit 2 ;;
esac
