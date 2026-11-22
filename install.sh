#!/usr/bin/env bash
# Installs Perfect Handoff for every supported agent CLI found on this machine.
#
# usage: ./install.sh [--force] [--iterm2] | --uninstall
#
#   scripts + hook -> ~/.local/share/perfect-handoff/        (one copy for all CLIs)
#   SKILL.md       -> ~/.claude/skills/handoff/               Claude Code (Grok reads it too)
#                     ${CODEX_HOME:-~/.codex}/skills/handoff/ Codex
#                     ~/.gemini/config/skills/handoff/        Antigravity CLI (agy)
#                     ${GROK_HOME:-~/.grok}/skills/handoff/   Grok
#   A SKILL.md goes only to CLIs that are installed. An existing "handoff" skill that is
#   not from Perfect Handoff stays untouched, unless you pass --force.
#   --iterm2 also creates ~/.local/share/perfect-handoff/venv with the iterm2 Python module
#   (pinned version, from PyPI) for auto-close and tab titles.
#   --uninstall removes only files that Perfect Handoff installed.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/handoff"
DEST="$HOME/.local/share/perfect-handoff"
MARK="perfect-handoff/scripts"   # every Perfect Handoff SKILL.md contains this path
ITERM2_VERSION="2.22"
MODE=install; FORCE=0; WITH_ITERM2=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --iterm2) WITH_ITERM2=1 ;;
    --uninstall) MODE=uninstall ;;
    *) echo "usage: ./install.sh [--force] [--iterm2] | --uninstall" >&2; exit 2 ;;
  esac
done
[ -f "$SRC/SKILL.md" ] || { echo "ERROR: run this from the perfect-handoff folder" >&2; exit 2; }

targets() {  # "<cli> <skills dir>"
  echo "claude $HOME/.claude/skills"
  echo "codex ${CODEX_HOME:-$HOME/.codex}/skills"
  echo "agy $HOME/.gemini/config/skills"
  echo "grok ${GROK_HOME:-$HOME/.grok}/skills"
}

if [ "$MODE" = "uninstall" ]; then
  targets | while read -r cli dir; do
    f="$dir/handoff/SKILL.md"
    if [ -f "$f" ] && grep -q "$MARK" "$f"; then rm -f -- "$f"; rmdir -- "$dir/handoff" 2>/dev/null || true; echo "removed  $cli: $f"; fi
  done
  [ -d "$DEST" ] && rm -rf -- "$DEST" && echo "removed  $DEST"
  exit 0
fi

mkdir -p "$DEST"
rm -rf -- "$DEST/scripts" "$DEST/hooks"
cp -R "$SRC/scripts" "$SRC/hooks" "$DEST/"
find "$DEST" -name '__pycache__' -prune -exec rm -rf {} +
chmod 755 "$DEST"/scripts/*.sh "$DEST"/scripts/*.py "$DEST"/hooks/*.py
echo "scripts  $DEST"

targets | while read -r cli dir; do
  if ! command -v "$cli" >/dev/null 2>&1; then echo "skipped  $cli: not installed"; continue; fi
  f="$dir/handoff/SKILL.md"
  if [ -e "$f" ] && ! grep -q "$MARK" "$f" && [ "$FORCE" != "1" ]; then
    echo "skipped  $cli: $f is another handoff skill (use --force to replace it)"; continue
  fi
  mkdir -p "$dir/handoff"
  cp "$SRC/SKILL.md" "$f"
  echo "skill    $cli: $f"
done

if [ "$WITH_ITERM2" = "1" ]; then
  python3 -m venv "$DEST/venv" && "$DEST/venv/bin/pip" install -q "iterm2==$ITERM2_VERSION" \
    && echo "iterm2   $DEST/venv (iterm2 $ITERM2_VERSION)"
fi

cat <<'EOF'

Optional for Claude Code - the context watcher hook. Add to ~/.claude/settings.json:
  "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command",
    "command": "python3 ~/.local/share/perfect-handoff/hooks/context_watcher.py 2>/dev/null || true",
    "timeout": 10 } ] } ] }
For auto-close and tab titles: enable iTerm2 > Settings > General > Magic > Enable
Python API, and run ./install.sh --iterm2 once (or set HANDOFF_ITERM2_PYTHON).
EOF
