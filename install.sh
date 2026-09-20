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

# One credential, and it has to work from any directory.
#
# `direnv` exports .env only inside this checkout, but the skill invokes
# `open-agent` by name from wherever the host coding agent is running — usually
# some other project entirely. A key scoped to one directory cannot
# authenticate a command that runs everywhere. ADR 0012.
#
# The key is never printed, and an existing file is never overwritten: rotating
# is the user's business, and clobbering a key they just set would be the worst
# possible time to be helpful.
CRED_FILE="$HOME/.config/open-agent/credentials"
if [ ! -s "$CRED_FILE" ]; then
  KEY="${TYPESAFE_API_KEY:-}"
  # Reuse direnv's own .env parser rather than writing a worse one here.
  if [ -z "$KEY" ] && [ -f "$ROOT/.envrc" ] && command -v direnv >/dev/null 2>&1; then
    KEY="$(direnv exec "$ROOT" sh -c 'printf %s "${TYPESAFE_API_KEY:-}"' 2>/dev/null || true)"
  fi
  if [ -n "$KEY" ]; then
    mkdir -p "$(dirname "$CRED_FILE")"
    (umask 077; printf %s "$KEY" >"$CRED_FILE")
    chmod 600 "$CRED_FILE"
    echo "  $CRED_FILE (copied from the environment; not printed)"
  fi
  unset KEY
fi

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

And one credential. The vendor is TypeSafe; Jev is the model. If the key was
already in the environment it has just been written to
~/.config/open-agent/credentials, which is where the installed command looks
when it runs outside this checkout. Otherwise:

  mkdir -p ~/.config/open-agent
  printf %s "$TYPESAFE_API_KEY" > ~/.config/open-agent/credentials
  chmod 600 ~/.config/open-agent/credentials

Keys are issued at https://console.typesafe.ai/keys

Check it with:  cd ~ && open-agent observe --app Finder
NOTE
