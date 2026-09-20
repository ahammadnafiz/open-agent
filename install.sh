#!/bin/sh
# Install open-agent: the binaries onto PATH, and the skill where the host
# coding agent will find it.
#
# The skill file alone is not an installation. It tells the host to run
# `open-agent run …`, so the binary has to be resolvable by name or the very
# first thing the skill does is fail.
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/open-agent}"

echo "building release…"
swift build -c release --package-path "$ROOT"
BUILT="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

mkdir -p "$BIN_DIR" "$SKILL_DIR"

# Symlinked, not copied, so a rebuild is picked up without reinstalling.
# The tradeoff is that `swift package clean` leaves dangling links; `--copy`
# is there for anyone who would rather have a stable artifact.
MODE="${1:-symlink}"
for tool in open-agent Probe; do
  if [ "$MODE" = "--copy" ]; then
    cp -f "$BUILT/$tool" "$BIN_DIR/$tool"
  else
    ln -sf "$BUILT/$tool" "$BIN_DIR/$tool"
  fi
  echo "  $BIN_DIR/$tool"
done

cp -f "$ROOT/skills/claude-code/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "  $SKILL_DIR/SKILL.md"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "WARNING: $BIN_DIR is not on your PATH."
     echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

cat <<'NOTE'

Two grants are needed, and both are per-binary — a rebuilt executable is a new
code identity, so macOS forgets it:

  Accessibility     System Settings > Privacy & Security > Accessibility
  Screen Recording  only for needs_eyes screenshots (tiers 3-4)

And one credential. The vendor is TypeSafe; Jev is the model:

  export TYPESAFE_API_KEY=...        keys at https://console.typesafe.ai/keys

Check it with:  open-agent observe --app Finder
NOTE
