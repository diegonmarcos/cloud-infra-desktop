#!/bin/sh
# kali-data init — copies bulk data sets into bind-mounted volumes so
# kali-os can mount them read-only at /usr/share/{wordlists,seclists,exploitdb}.
#
# Reads DATA_DIRS env (space-separated dir names under /usr/share) and
# DEST env (target volume mount, default /vol). Idempotent: skips dirs
# that are already populated.

set -eu

DEST="${DEST:-/vol}"
DATA_DIRS="${DATA_DIRS:-wordlists seclists exploitdb}"

mkdir -p "$DEST"
echo "[kali-data] DEST=$DEST  DIRS=$DATA_DIRS"

for d in $DATA_DIRS; do
  src="/usr/share/$d"
  dst="$DEST/$d"

  if [ ! -d "$src" ]; then
    echo "[kali-data] skip: $src not in this image"
    continue
  fi

  if [ -d "$dst" ] && [ "$(ls -A "$dst" 2>/dev/null | head -1)" ]; then
    echo "[kali-data] ✓ $dst already populated — skipping"
    continue
  fi

  echo "[kali-data] → populating $dst from $src"
  cp -an "$src/." "$dst/" 2>/dev/null || cp -a "$src/." "$dst/"
  echo "[kali-data] ✓ $dst done ($(du -sh "$dst" 2>/dev/null | cut -f1))"
done

echo "[kali-data] init complete"
