#!/usr/bin/env bash
# Self-check for hm-refreeze-files.sh. It DELETES files in $HOME, so the three
# cases that matter are pinned here: it removes an unmodified copy, it keeps a
# hand-edited one, and it keeps a file the previous generation never managed.
#
# Runs against a throwaway HOME — no nix, no switch, no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

GEN="$FAKE/gen"
mkdir -p "$GEN/home-files" "$FAKE/.local/state/nix/profiles"
ln -s "$GEN" "$FAKE/.local/state/nix/profiles/home-manager"

# What the old generation linked into place.
printf 'declarative content\n' > "$GEN/home-files/.bashrc"
printf 'declarative content\n' > "$GEN/home-files/.zshrc"
mkdir -p "$GEN/home-files/.config/sub"
printf 'nested\n' > "$GEN/home-files/.config/sub/conf"

# What is sitting in HOME when the next switch starts.
printf 'declarative content\n'            > "$FAKE/.bashrc"        # our copy, untouched
printf 'declarative content\nhand edit\n' > "$FAKE/.zshrc"         # owner edited it
printf 'brand new target\n'               > "$FAKE/.newfile"       # old gen never had it
mkdir -p "$FAKE/.config/sub"
printf 'nested\n'                         > "$FAKE/.config/sub/conf"  # our copy, nested
ln -s /dev/null "$FAKE/.alink"                                      # already linked

TARGETS="$FAKE/targets"
printf '%s\n' .bashrc .zshrc .newfile .config/sub/conf .alink > "$TARGETS"

echo "== refreeze on a HOME left behind by unfreeze =="
HOME="$FAKE" TARGETS_FILE="$TARGETS" bash "$HERE/hm-refreeze-files.sh" >/dev/null 2>&1

[ -e "$FAKE/.bashrc" ]           && bad "unmodified copy removed"          || ok "unmodified copy removed (linkGeneration now has a clean slot)"
[ -e "$FAKE/.config/sub/conf" ]  && bad "unmodified nested copy removed"   || ok "unmodified nested copy removed"
grep -q 'hand edit' "$FAKE/.zshrc" 2>/dev/null && ok "hand-edited dotfile KEPT (home-manager still backs it up)" || bad "hand-edited dotfile was destroyed"
[ -f "$FAKE/.newfile" ]          && ok "file the old generation never managed is KEPT" || bad "unknown file was destroyed"
[ -L "$FAKE/.alink" ]            && ok "existing symlink left alone"       || bad "existing symlink was touched"

echo "== no previous generation: nothing is ever deleted =="
rm -f "$FAKE/.local/state/nix/profiles/home-manager"
printf 'declarative content\n' > "$FAKE/.bashrc"
HOME="$FAKE" TARGETS_FILE="$TARGETS" bash "$HERE/hm-refreeze-files.sh" >/dev/null 2>&1
[ -f "$FAKE/.bashrc" ] && ok "first switch on a fresh device is a no-op" || bad "deleted a file with no generation to compare against"

echo "== no TARGETS_FILE: no-op, never a crash =="
HOME="$FAKE" bash "$HERE/hm-refreeze-files.sh" >/dev/null 2>&1 && ok "missing TARGETS_FILE exits 0" || bad "missing TARGETS_FILE is fatal"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
