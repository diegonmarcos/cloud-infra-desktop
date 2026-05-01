#!/usr/bin/env bash
# capture-session.sh — snapshot the current Plasma session into git.
#
# USE CASE: after you arranged the perfect 4-desktop session and logged
# out + back in (which makes Plasma write the session state to disk),
# run this script to capture that state into the modules/desktop/session-
# snapshot/ directory.
#
# After capture, build.sh switch flips loginMode → restoreSavedSession
# and the deploy mechanism in session-restore.nix re-applies the snapshot
# on every login.
#
# WORKFLOW:
#   1. (one-time) Set loginMode=restorePreviousSession in plasma.nix
#      (already done by session-restore.nix when no snapshot exists)
#   2. Arrange your perfect 4-desktop session
#   3. Log out (Plasma writes state files on logout)
#   4. Log back in (verify apps re-appear correctly)
#   5. Run THIS script
#   6. build.sh switch (deploys snapshot, switches loginMode)
#
set -euo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
SNAPSHOT_DIR="$REPO_DIR/session-snapshot"
SOURCE_DIR="$HOME/.config/session"
KSMSERVERRC="$HOME/.config/ksmserverrc"

# ─── 1. Sanity checks ──────────────────────────────────────────────────
[ -d "$SOURCE_DIR" ] || { echo "FAIL: $SOURCE_DIR not found"; exit 2; }
SESSION_FILES=$(find "$SOURCE_DIR" -maxdepth 1 -type f | wc -l)
[ "$SESSION_FILES" -gt 0 ] || { echo "FAIL: no session files in $SOURCE_DIR"; exit 2; }

# Verify the saved session has actual clients (count > 0 in a [Session:...] block)
SESSION_COUNT=$(awk '
  /^\[Session:/ { in_session=1; next }
  /^\[/         { in_session=0 }
  in_session && /^count=/ { gsub(/count=/, ""); if ($0+0 > 0) print $0 }
' "$KSMSERVERRC" 2>/dev/null | head -1)
if [ -z "$SESSION_COUNT" ] || [ "$SESSION_COUNT" -eq 0 ]; then
  echo "FAIL: no [Session:...] in ksmserverrc has count>0 — log out + log in first"
  echo "      (this is what triggers Plasma to actually save state)"
  exit 2
fi
echo "  ✅ found saved session with $SESSION_COUNT clients"

# ─── 2. Copy session files ─────────────────────────────────────────────
echo "  copying $SESSION_FILES files from $SOURCE_DIR → snapshot"
rm -f "$SNAPSHOT_DIR"/*[!.]*  # clear old snapshot, keep dotfiles
cp "$SOURCE_DIR"/* "$SNAPSHOT_DIR"/

# ─── 3. Extract [Session: ...] block from ksmserverrc ──────────────────
awk '
  /^\[Session: saved at previous logout\]/ { in_block=1; print; next }
  in_block && /^\[/ && !/^\[Session: saved at previous logout\]/ { in_block=0 }
  in_block { print }
' "$KSMSERVERRC" > "$SNAPSHOT_DIR/ksmserverrc.fragment"
LINES=$(wc -l < "$SNAPSHOT_DIR/ksmserverrc.fragment")
echo "  extracted $LINES lines of ksmserverrc [Session:...] block"

# ─── 4. Marker file — session-restore.nix uses this to detect ready ────
date -u +%Y-%m-%dT%H:%M:%SZ > "$SNAPSHOT_DIR/captured"

# ─── 5. Summary ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Session snapshot captured into:"
echo "    $SNAPSHOT_DIR"
echo "  $(ls "$SNAPSHOT_DIR" | wc -l) files total"
echo ""
echo "  Next:"
echo "    1. cd ~/git/unix && git add -A && git diff --cached --stat"
echo "    2. ~/git/unix/ba_flakes_desktop/build.sh switch"
echo "       (loginMode flips to restoreSavedSession; snapshot deploys)"
echo "    3. log out + back in to verify the captured session restores"
echo "═══════════════════════════════════════════════════════════"
