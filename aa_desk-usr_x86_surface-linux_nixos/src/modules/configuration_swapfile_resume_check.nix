# Swapfile resume-offset invariant gate (POST-INCIDENT 2026-05-15).
#
# WHY THIS EXISTS — historical context
# ────────────────────────────────────
# Original purpose: a btrfs swapfile's first physical block (4-KiB units, as
# reported by `btrfs inspect-internal map-swapfile -r`) drifts whenever btrfs
# balance/dedup runs or the swapfile is recreated/resized. systemd-logind's
# hibernate path then refuses with:
#   "Call to Hibernate failed: Specified resume device is missing or is not
#    an active swap device"
# This module used to silently SELF-HEAL by writing the actual offset to
# /sys/power/resume_offset and logging a warning that cmdline was stale.
#
# WHY THAT WAS WRONG — the 2026-05-15 incident
# ────────────────────────────────────────────
# Self-healing the /sys side made HIBERNATE ENTRY work, but the write target
# (the swapfile's current extents on btrfs) could overlap live metadata chunks
# because btrfs is free to place a NOCOW file anywhere in any data chunk. When
# hibernate fired, the compressed RAM image landed bytewise on top of chunk 73's
# DUP-mirrored metadata at physical 39.1/39.5 GB — two random-looking blobs
# (DUP mirrors should be identical; foreign overwrite proven by mirror divergence).
# Pool was unrecoverable. See incident_2026-05-15_pool_hibernate_corruption.md.
#
# WHAT THIS MODULE DOES NOW
# ─────────────────────────
# - The swapfile MUST live on an ext4 (or xfs) filesystem; mounting on btrfs is
#   refused.
# - The cmdline, /sys, and the swapfile's actual first physical extent MUST
#   agree. Any drift → mask systemd-hibernate.service this boot. No more silent
#   self-heal. Force user to redeploy boot.json + switch + reboot.
# - The bootloader-engine SoT is `~/git/cloud-unix/aa_bootloader/src/boot.json`
#   (`swap_hibernate.resume_offset`). Re-run `build.sh deploy --target nixos`
#   to repopulate from a fresh `filefrag -v -b4096 <swapfile>`.
{ config, pkgs, lib, ... }:

let
  # /etc/cloud-data/boot.json is already deployed by
  # configuration_pre-hibernate-warning.nix's environment.etc declaration —
  # reused here as-is (NOT redeclared; duplicate environment.etc paths are
  # a build error). This module reads it at RUNTIME via jq instead of
  # baking swap_hibernate.* values in at Nix-eval time.
  swapfileResumeCheckPkg = pkgs.writeShellApplication {
    name = "swapfile-resume-offset-check";
    runtimeInputs = with pkgs; [ e2fsprogs coreutils util-linux systemd gawk gnugrep jq ];
    text = builtins.readFile ./swapfile-resume-offset-check.sh;
  };
in
{
  systemd.services."swapfile-resume-offset-check" = {
    description = "Verify /sys/power/resume_offset matches the swapfile's actual first physical block (drift defeats hibernation)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "swap.target" "local-fs.target" ];
    before      = [ "sleep.target" "systemd-logind.service" ];
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      Slice          = "os-essentials.slice";
      OOMScoreAdjust = -900;
      ExecStart      = "${swapfileResumeCheckPkg}/bin/swapfile-resume-offset-check";
    };
  };
}
