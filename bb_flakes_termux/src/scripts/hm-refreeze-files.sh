#!/usr/bin/env bash
# hm-refreeze-files — delete the writable copies hm-unfreeze-files.sh made, just
# before linkGeneration looks at those paths.
#
# THE LOOP THIS KILLS (diagnosed 2026-09-13):
#   1. hm-unfreeze-files.sh runs entryAfter linkGeneration and replaces every
#      managed symlink with a `cp -RL` copy, so the deployed dotfiles are
#      editable. After activation, $HOME/.bashrc is a REGULAR FILE.
#   2. The next switch therefore finds "existing file in the way" for every
#      single managed path — .bashrc .zshrc .profile .zshenv .bash_profile
#      .manpath .gitignore claude-fix.sh and everything under .claude/ .config/.
#   3. build.sh answers that with HOME_MANAGER_BACKUP_EXT="hm-bak-$(date ...)",
#      so the switch cannot abort. A timestamped extension is required there
#      (a fixed one makes the SECOND conflict on a file fatal), which means
#      every switch mints a fresh, differently-named backup of every managed
#      file. Nothing ever converges: 3 switches over 2026-09-02..03 left three
#      complete 8-file sets in $HOME, and prune_hm_backups only removes them
#      once they are 7 days old, by which time the next ones exist.
# Unfreeze was written as half a design. This is the other half: if the file in
# the way is a copy WE made and nobody edited, there is no conflict to record,
# so remove it and let linkGeneration link cleanly. Zero backups per switch.
#
# WHAT IS DELIBERATELY NOT TOUCHED: a dotfile the owner actually hand-edited
# differs from the store copy, survives this pass, and is backed up exactly as
# before. That backup is a REAL conflict between an imperative edit and the
# declarative source, and preserving it is the only thing the backup extension
# was ever for. Losing an edit silently would be a far worse bug than clutter.
#
# Env contract: TARGETS_FILE — home-relative paths, one per line. It is the same
# derivation hm-unfreeze-files.sh reads (see modules/hm-runtime.nix), so the two
# passes can never drift onto different path sets.
#
# Runs entryBefore linkGeneration: that is the entry which both checks the link
# targets and moves whatever blocks them aside, so this must land ahead of it.
# At that point the home-manager profile symlink still points at the OLD
# generation, which is precisely the content unfreeze copied out.

[ -n "${TARGETS_FILE:-}" ] || exit 0
[ -r "$TARGETS_FILE" ] || exit 0

OLD_HOME_FILES="$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" 2>/dev/null)/home-files"
# First switch on a fresh device: no previous generation, so nothing this script
# could have created. Every file in the way is genuinely foreign — leave it to
# home-manager's own backup path.
[ -d "$OLD_HOME_FILES" ] || exit 0

removed=0
while IFS= read -r target_relative; do
    [ -n "$target_relative" ] || continue
    target="$HOME/$target_relative"

    # Already a symlink: no conflict, and following it into the store to compare
    # would be pointless. -L is tested FIRST because -f follows symlinks.
    [ -L "$target" ] && continue

    # Regular files only. `cp -RL` also deep-copies directory targets, but no
    # directory has ever produced a backup here, and diffing whole trees on
    # every switch would cost more than the clutter it removes.
    [ -f "$target" ] || continue

    # The proof of ownership: byte-identical to what the old generation linked
    # there. A new target absent from the old generation fails this and stays.
    cmp -s "$target" "$OLD_HOME_FILES/$target_relative" || continue

    rm -f "$target" && removed=$((removed + 1))
done < "$TARGETS_FILE"

[ "$removed" -gt 0 ] && echo "refreeze: removed $removed unmodified writable copies (no backup needed)"
exit 0
