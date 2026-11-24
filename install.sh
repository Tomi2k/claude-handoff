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
#   A SKILL.md goes only to CLIs that are installed. manifest.txt records every installed
#   skill file with its SHA-256. An existing file that is not in the manifest with the same
#   hash (another skill, or your own edits) stays untouched, unless you pass --force;
#   then the replaced file is kept as SKILL.md.bak-<date>.
#   Symlinked destinations are never written.
#   --iterm2 also creates ~/.local/share/perfect-handoff/venv with the iterm2 Python module
#   for auto-close and tab titles. The module and its dependencies come from PyPI in the
#   exact versions of requirements-iterm2.txt, and pip checks every download against the
#   SHA-256 hashes in that file.
#   --uninstall removes only unchanged files from the manifest, plus scripts, hooks and venv.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/skills/handoff"
REQ="$ROOT/requirements-iterm2.txt"
DEST="$HOME/.local/share/perfect-handoff"
MANIFEST="$DEST/manifest.txt"
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
# The install folder is created, replaced and removed by this script: never through a symlink.
for p in "$DEST" "$DEST/scripts" "$DEST/hooks" "$DEST/venv" "$MANIFEST"; do
  if [ -L "$p" ]; then echo "ERROR: $p is a symlink - remove it first" >&2; exit 2; fi
done

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
ours() { [ -f "$MANIFEST" ] && grep -Fxq "$(sha "$1")  $1" "$MANIFEST"; }   # unchanged file we installed
targets() {  # "<cli> <skills dir>"
  echo "claude $HOME/.claude/skills"
  echo "codex ${CODEX_HOME:-$HOME/.codex}/skills"
  echo "agy $HOME/.gemini/config/skills"
  echo "grok ${GROK_HOME:-$HOME/.grok}/skills"
}

if [ "$MODE" = "uninstall" ]; then
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r line; do
      f="${line#*  }"
      if [ -L "$f" ] || [ -L "$(dirname "$f")" ]; then echo "kept     $f (symlink)"; continue; fi
      [ -f "$f" ] || continue
      if ours "$f"; then rm -f -- "$f"; rmdir -- "$(dirname "$f")" 2>/dev/null || true; echo "removed  $f"
      else echo "kept     $f (changed since install)"; fi
    done < "$MANIFEST"
  fi
  rm -rf -- "$DEST/scripts" "$DEST/hooks" "$DEST/venv"
  rm -f -- "$MANIFEST"
  rmdir -- "$DEST" 2>/dev/null && echo "removed  $DEST" || echo "kept     $DEST (other files inside)"
  exit 0
fi

# Scripts: copy to a staging folder first, then swap, so a failed copy keeps the old version.
mkdir -p "$DEST"
STAGE=$(mktemp -d "$DEST/.stage.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
cp -R "$SRC/scripts" "$SRC/hooks" "$STAGE/"
find "$STAGE" -name '__pycache__' -prune -exec rm -rf {} +
chmod 755 "$STAGE"/scripts/*.sh "$STAGE"/scripts/*.py "$STAGE"/hooks/*.py
rm -rf -- "$DEST/scripts" "$DEST/hooks"
mv "$STAGE/scripts" "$STAGE/hooks" "$DEST/"
echo "scripts  $DEST"

NEW_MANIFEST=$(mktemp "$DEST/.manifest.XXXXXX")
[ -f "$MANIFEST" ] && cp "$MANIFEST" "$NEW_MANIFEST"
while read -r cli dir; do
  if ! command -v "$cli" >/dev/null 2>&1; then echo "skipped  $cli: not installed"; continue; fi
  f="$dir/handoff/SKILL.md"
  if [ -L "$dir/handoff" ] || [ -L "$f" ]; then echo "skipped  $cli: $f is a symlink"; continue; fi
  if [ -e "$f" ] && ! ours "$f" && [ "$FORCE" != "1" ]; then
    echo "skipped  $cli: $f is another or a changed handoff skill (--force replaces it)"; continue
  fi
  mkdir -p "$dir/handoff"
  if [ -e "$f" ] && ! ours "$f"; then   # --force: keep the replaced file next to it
    cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)" && echo "backup   $f.bak-*"
  fi
  cp "$SRC/SKILL.md" "$f"
  grep -v -F "  $f" "$NEW_MANIFEST" > "$NEW_MANIFEST.tmp" || true
  mv "$NEW_MANIFEST.tmp" "$NEW_MANIFEST"
  echo "$(sha "$f")  $f" >> "$NEW_MANIFEST"
  echo "skill    $cli: $f"
done < <(targets)
mv "$NEW_MANIFEST" "$MANIFEST"
chmod 600 "$MANIFEST"

if [ "$WITH_ITERM2" = "1" ]; then
  [ -f "$REQ" ] || { echo "ERROR: $REQ is missing" >&2; exit 1; }
  # -I: no module from the current folder or PYTHONPATH is imported while the venv is
  # built. --require-hashes: pip installs only files whose SHA-256 is listed in $REQ.
  # --only-binary: wheels only, so no build step downloads further (unlisted) packages.
  if python3 -I -m venv "$DEST/venv" \
      && "$DEST/venv/bin/python" -I -m pip install -q --disable-pip-version-check --require-hashes --only-binary :all: -r "$REQ" \
      && "$DEST/venv/bin/python" -I -c "import iterm2"; then
    echo "iterm2   $DEST/venv ($(grep -m1 -o '^iterm2==[0-9.]*' "$REQ"), hashes checked)"
  else
    echo "ERROR: could not set up $DEST/venv from $REQ" >&2; exit 1
  fi
fi

cat <<'EOF'

Optional for Claude Code - the context watcher hook. Add to ~/.claude/settings.json:
  "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command",
    "command": "python3 -I ~/.local/share/perfect-handoff/hooks/context_watcher.py 2>/dev/null || true",
    "timeout": 10 } ] } ] }
For auto-close and tab titles: enable iTerm2 > Settings > General > Magic > Enable
Python API, and run ./install.sh --iterm2 once.
EOF
