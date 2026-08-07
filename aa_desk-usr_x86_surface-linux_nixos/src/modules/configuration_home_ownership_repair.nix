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
#
# ⚠ NESTED-MOUNT HAZARD (2026-06-24 incident — Waydroid keystore corruption)
# -------------------------------------------------------------------------
# The original repair ran `chown -R diego:users ~/.local` whenever it found a
# single non-diego file under `.local`. But `~/.local/share/waydroid` is a
# NESTED btrfs subvol mount holding Android `/data`, whose files are owned by
# LEGITIMATE foreign uids (Android keystore=1017, audioserver=1041, system=1000…
# — no idmap, so Android uid == host uid). The recursive chown flattened ALL of
# them to diego(1000) on EVERY rebuild, so keystore2 (uid 1017) could no longer
# open /data/misc/keystore/*.sqlite → SQLITE_CANTOPEN(14) → keystore2 abort →
# system_server crash-loop → the Waydroid home screen looked "reset" after every
# single nixos-rebuild.
#
# FIX: `find -xdev` so detection AND repair stay on the home subvol and never
# descend into a nested mount, and chown the offending paths INDIVIDUALLY
# (never `-R`, which would cross the mount). Generic: protects any present or
# future nested mount under a fragile tree, no path hardcoding needed.

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

  # Runtime data for home-ownership-repair.sh — builtins.toJSON straight from
  # the managedUsers/fragilePaths lists above, so the deployed JSON can never
  # drift from this file's Nix source of truth. NAMES AND PATHS ONLY — no
  # credential material belongs in this JSON.
  homeOwnershipRepairJson = builtins.toJSON {
    managed_users = managedUsers;
    fragile_paths = fragilePaths;
  };

  # Extracted from the formerly per-user Nix-interpolated `mkUserBlock`
  # (lib.concatMapStrings over managedUsers) — now ONE data-driven script;
  # see home-ownership-repair.sh for the full extraction/behaviour notes.
  homeOwnershipRepairScript = pkgs.writeShellApplication {
    name = "home-ownership-repair";
    runtimeInputs = with pkgs; [ jq findutils gnugrep coreutils util-linux ];
    text = builtins.readFile ./home-ownership-repair.sh;
  };

in {
  # Runtime data for home-ownership-repair.sh, read via jq at RUNTIME. New
  # path — verified against the already-declared environment.etc."cloud-data/..."
  # set, no collision.
  environment.etc."cloud-data/home-ownership-repair.json".text = homeOwnershipRepairJson;

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
        ${homeOwnershipRepairScript}/bin/home-ownership-repair
      ) || true
    '';
  };
}
