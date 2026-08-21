#!/usr/bin/env bash
# dolphin-view-defaults.sh — make Details the default Dolphin view mode.
# Run from home.activation.dolphinViewDefaults in ./plasma.nix.
#
# WHY A SCRIPT AND NOT home.file
# The value lives in
#   ~/.local/share/dolphin/view_properties/global/.directory
# which Dolphin rewrites on its own — it carries a Timestamp= key it bumps on
# every change (observed being rewritten mid-session, 2026-08-21 13:32). A
# /nix/store symlink there gets replaced by a real file the first time Dolphin
# touches it, exactly like konsolerc and "Profile 1.profile" (see
# app_especific/konsole.nix for the same problem and the same shape of fix).
#
# ViewMode values, from the live file rather than documentation:
#   0 = Icons   1 = Compact   2 = Details
# It was 1 here; the declared default is 2.
#
# THE TRADE, STATED PLAINLY
# This is idempotent ENFORCEMENT, not a seed: it rewrites ViewMode on every
# activation. That means changing the default view in Dolphin's GUI will not
# survive the next switch — to change it, change it here. That is deliberate,
# because "Details is the default" was asked for as a declaration. Per-folder
# view choices are unaffected; this is only the global default.
#
# GlobalViewProps=true in dolphinrc (declared in plasma.nix) is what makes this
# file apply to every folder instead of Dolphin keeping per-directory
# properties. Without it this value is only the fallback for folders that have
# never been visited, which reads as "the setting did nothing".

DIR="$HOME/.local/share/dolphin/view_properties/global"
DST="$DIR/.directory"
WANT=2

mkdir -p "$DIR"

# Replace a store symlink left by an earlier generation with a real file, so
# Dolphin can write to it.
if [ -L "$DST" ]; then
  rm -f "$DST"
  echo "[dolphin] replaced store symlink at $DST with a writable file"
fi

if [ ! -e "$DST" ]; then
  printf '[Dolphin]\nVersion=4\nViewMode=%s\n' "$WANT" > "$DST"
  echo "[dolphin] seeded global view properties (ViewMode=$WANT, Details)"
  exit 0
fi

# Both tools or neither. kconfig comes from runtimeInputs, so a miss means the
# module was changed and this would otherwise fall through to "kreadconfig6
# returns nothing, therefore CUR != WANT, therefore write" — and then die on the
# write instead, after already deciding the value was wrong. Bail loudly.
if ! command -v kreadconfig6 >/dev/null 2>&1 || ! command -v kwriteconfig6 >/dev/null 2>&1; then
  echo "[dolphin] kconfig tools unavailable — leaving $DST alone" >&2
  exit 0
fi

CUR="$(kreadconfig6 --file "$DST" --group Dolphin --key ViewMode 2>/dev/null || true)"
if [ "$CUR" != "$WANT" ]; then
  kwriteconfig6 --file "$DST" --group Dolphin --key ViewMode "$WANT"
  echo "[dolphin] default view mode: ${CUR:-unset} -> $WANT (Details)"
fi

exit 0
