#!/usr/bin/env bash
# NOTE: also provided by the my-ai binary self-extract (~/.local/bin); redundant, removal deferred.
export MALLOC_ARENA_MAX=2
export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=2048"
export CLAUDE_TMP="$HOME/tmp/claude"
mkdir -p "$CLAUDE_TMP"
export TMPDIR="$CLAUDE_TMP"
exec claude "$@"
