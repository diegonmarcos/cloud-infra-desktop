#!/usr/bin/env bash
REAL="$HOME/.local/bin/claude"
if [ ! -e "$REAL" ]; then
  REAL=$(ls -t "$HOME"/.local/share/claude/versions/* 2>/dev/null | head -1)
fi
[ -n "$REAL" ] || { echo "claude binary not found — run claude-rescue" >&2; exit 127; }
exec @glibcLib@/ld-linux-x86-64.so.2 "$REAL" "$@"
