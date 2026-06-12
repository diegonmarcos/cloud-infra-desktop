# Defensive `chown` on every nixos-rebuild for known-fragile user home paths.
#
# Why this exists
# ---------------
# On 2026-05-16, after a recovery session that ran many `sudo` operations
# inside chroots, `home-manager switch` failed in `linkGeneration` with:
#
#   ln: failed to create symbolic link
#     '/home/diego/.claude/hooks/a-context-inject-memory.sh':
#     Permission denied
#
# Root cause: `/home/diego/.claude/hooks` was owned by root:root — created
# during one of the chroot-as-root operations that touched the user's home
# (claude-code invoked as root, or some install/restore step). Once a single
# directory under $HOME flips to root ownership, the next standalone HM apply
# (which runs as the user) can't write through it.
#
# This module addresses the *class* of bug: any path under critical user-dir
# trees (.claude, .config, .local, .ssh) that is somehow root-owned gets
# repaired on every activation. Loud — logs the offending paths to the
# journal so we know the bug is recurring (and where the root-write came in).
#
# This is a defense-in-depth layer, not a substitute for fixing the root
# writers — but any install.sh / chroot recovery flow that goes through
# `nixos-rebuild switch` afterwards will self-heal at activation time.

{ config, lib, pkgs, ... }:

let
  # Users whose homes we manage. Add more here if guest/other accounts grow
  # their own home-manager configs.
  managedUsers = [
    { name = "diego"; group = "users"; }
  ];

  # Subdirs under each $HOME that have a history of being root-corrupted by
  # install / recovery / chroot flows. Each one is checked independently so
  # a missing tree is just skipped (no error).
  fragilePaths = [ ".claude" ".config" ".local" ".ssh" ];

  mkUserBlock = u: ''
    if [ -d /home/${u.name} ]; then
      for path in ${lib.concatStringsSep " " fragilePaths}; do
        target=/home/${u.name}/$path
        if [ -e "$target" ]; then
          bad=$(${pkgs.findutils}/bin/find "$target" ! -user ${u.name} -print 2>/dev/null | head -n 5)
          if [ -n "$bad" ]; then
            echo "[home-ownership-repair] ${u.name}: wrong-owner files under $target — repairing"
            echo "$bad" | while read -r f; do echo "  $f"; done
            ${pkgs.coreutils}/bin/chown -R ${u.name}:${u.group} "$target"
          fi
        fi
      done
    fi
  '';

in {
  system.activationScripts.repairUserHomeOwnership = {
    # Run after `users` (target user must exist) and after `specialfs` (so
    # the persistent home subvol is mounted under impermanence root=tmpfs).
    deps = [ "users" "specialfs" ];

    text = ''
      # Any repair is a signal that some upstream code wrote to user home
      # as root — tolerate missing paths / transient races without blocking
      # the rest of activation.
      #
      # ⚠ SUBSHELL, NOT `exit` (2026-06-12 incident): activation snippets are
      # concatenated into ONE activate script. A bare `exit 0` here ended the
      # WHOLE script early — skipping every later snippet (tmpBtrfsSubvols,
      # udevd, var, zzz-verify) AND the final `ln -sfn ... /run/current-system`,
      # so the system ran the new units while current-system still pointed at
      # the previous generation. The subshell also contains `set +e` so it
      # can't leak into later snippets.
      (
        set +e
        ${lib.concatMapStrings mkUserBlock managedUsers}
      ) || true
    '';
  };
}
