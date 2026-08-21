#!/usr/bin/env bash
# default-session-reap.sh — remove the retired default-session launcher's
# deployed artifacts. Run from home.activation.reapDefaultSessionLauncher in
# ./session-default-config.nix.
#
# WHY THIS EXISTS AT ALL
# Deleting ./default-session.nix does not remove what it had already put on
# disk. home-manager only reclaims what it still owns as a /nix/store symlink,
# and on this box these are REGULAR files: `build.sh deploy` copies declared
# files into place for fast iteration, and its own log says "the next switch
# re-links these from the store". Once the declaration is gone there is no next
# re-link, so they would sit orphaned — unmanaged, invisible to a rebuild.
#
# And orphaned does not mean inert. ~/.config/autostart is scanned by ksmserver,
# not by home-manager, so a leftover .desktop keeps launching the layout on
# every login forever. That would leave the migration looking finished in git
# while the machine carried on exactly as before — 28 launcher invocations on
# the last login, per ~/.local/state/default-session.log.
#
# SAFETY
# Idempotent: after the first switch every path is gone and each run is a
# no-op, so this is safe to leave in place indefinitely. The list is the exact
# set default-session.nix used to deploy, spelled out in full — never a
# recursive sweep of ~/.config/autostart or ~/.local/share, which hold plenty
# that is not ours.
#
# Deliberately NOT touched: the .hm-bak-* / .hm-backup-* copies beside the json.
# home-manager wrote those as user data when it found a real file in the way;
# reaping is our business only for what we deployed.
#
# ponytail: the three paths are literals here rather than a *-reap.json read via
# jq. They are this module's own retired artifacts, not configuration — nobody
# tunes them, and the list stops changing the moment the migration lands. If a
# second module ever needs reaping, that is the point to make it data-driven.
#
# errexit is ON (pkgs.writeShellApplication prepends it) and that is fine here:
# every command below either succeeds or is guarded. `rm -f` on a path that
# passed the existence test does not fail, and an `if` whose condition is false
# yields 0. The explicit `exit 0` at the end is belt-and-braces so a false test
# on the final iteration can never become the script's exit status — the same
# class of bug that kept hm-auto-update from ever switching unattended.

STALE_PATHS=(
  "$HOME/.config/autostart/default-session.desktop"
  "$HOME/.local/share/default-session/default-session-launcher.sh"
  "$HOME/.local/share/default-session/default-session.json"
)

for p in "${STALE_PATHS[@]}"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    rm -f "$p"
    echo "[default-session] reaped orphaned $p (launcher retired 2026-08-21)"
  fi
done

# Drop the directory too, but only once it is empty — the .hm-bak-* copies above
# are expected to keep it alive, and rmdir failing on a non-empty dir is the
# desired outcome, not an error.
rmdir "$HOME/.local/share/default-session" 2>/dev/null \
  && echo "[default-session] removed now-empty ~/.local/share/default-session" \
  || true

exit 0
