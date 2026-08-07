# Session checkpoint — A SESSION FILE ON DISK AT ALL TIMES (2026-06-12).
#
# WHY THIS EXISTS
# ───────────────
# User requirement: the in-use session must always have an on-disk
# representation, surviving shutdown / crash / power-cut — not only at
# hibernate time. A continuously-current RAM image is impossible on bare
# metal (Linux has no incremental hibernation; the image must be a frozen
# point-in-time snapshot). What IS possible — and what this module does —
# is the filesystem half: apps persist their session state into $HOME
# continuously (browser sessionstore, editor autosave/swap, KDE configs,
# shell/tmux state), so a periodic READ-ONLY btrfs snapshot of the home
# subvolume is a genuine, restorable session checkpoint.
#
# Division of labor:
#   RAM session  → hibernate image in the swapfile (battery-watchdog,
#                  idle timers, manual) — exact, but event-driven.
#   File session → THIS — every N minutes, always present, survives
#                  everything including the events hibernate can't.
#
# Policy lives in cloud-data-session-checkpoint.json (interval, retention,
# subvol names). Snapshots are CoW: near-zero cost until files diverge.
# Nested subvolumes (container storage inside home) are excluded by btrfs
# semantics — they are not session state.
#
# The service runs with idle CPU/IO scheduling: it can never compete with
# the interactive session (same 2026-06-12 lesson as the nix-daemon
# throttle in configuration_nix.nix).
{ config, pkgs, lib, ... }:

let
  cfg = builtins.fromJSON (builtins.readFile ./cloud-data-session-checkpoint.json);
  enabled   = cfg.enabled or false;
  cp        = cfg.checkpoint;
  srcSubvol = cp.source_subvol;
  interval  = cp.interval_minutes;

  shutdownCheckpoint = (cfg.shutdown_checkpoint or {}).enabled or false;
  hibernateCheckpoint = (cfg.hibernate_checkpoint or {}).enabled or false;
  rebootWithSessionEnabled = (cfg.reboot_with_session or {}).enabled or false;

  # Shared checkpoint body (session-checkpoint.sh) — used by the periodic
  # timer service AND the shutdown/hibernate hooks (REBOOT MUST ALWAYS SAVE
  # A SNAPSHOT IN DISK). Which checkpoint is selected at runtime by tag (arg
  # 1); policy (btrfs_root/source_subvol/snapshot_dir/retention_count/
  # notify) is read at runtime via jq from the SAME JSON this .nix already
  # treats as source of truth (builtins.fromJSON above) — no new JSON
  # needed, just exposed to the running system via environment.etc below.
  sessionCheckpointScript = pkgs.writeShellApplication {
    name = "session-checkpoint";
    runtimeInputs = with pkgs; [ jq btrfs-progs coreutils util-linux gawk libnotify findutils ];
    text = builtins.readFile ./session-checkpoint.sh;
  };

  # `sudo reboot-with-session` — the RAM-session counterpart for restarts.
  # See ./reboot-with-session.sh for the full behaviour/contract comment.
  rebootWithSession = pkgs.writeShellApplication {
    name = "reboot-with-session";
    runtimeInputs = with pkgs; [ systemd coreutils util-linux ];
    text = builtins.readFile ./reboot-with-session.sh;
  };
in
{
  # Runtime data for session-checkpoint.sh — the SAME file this .nix reads
  # at eval time (builtins.fromJSON above), now also exposed to the running
  # system so the script can read it via jq at runtime. Path checked against
  # the already-declared environment.etc."cloud-data*" set — no collision.
  environment.etc."cloud-data/session-checkpoint.json".source = ./cloud-data-session-checkpoint.json;

  systemd.timers."session-checkpoint" = lib.mkIf enabled {
    description = "Session checkpoint — snapshot ${srcSubvol} every ${toString interval} min";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "5min";
      OnUnitActiveSec = "${toString interval}min";
      AccuracySec     = "1min";
    };
  };

  systemd.services."session-checkpoint" = lib.mkIf enabled {
    description = "Session checkpoint — read-only btrfs snapshot of ${srcSubvol} (session file on disk)";
    serviceConfig = {
      Type = "oneshot";
      # NEVER compete with the interactive session.
      Nice                = 19;
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass   = "idle";
      ExecStart = "${sessionCheckpointScript}/bin/session-checkpoint periodic";
    };
  };

  # REBOOT/SHUTDOWN MUST ALWAYS SAVE A SNAPSHOT IN DISK (hard requirement
  # 2026-06-12): final checkpoint on the way down, before unmounts. Same
  # shutdown-hook pattern as p5-snapshot-shutdown — DefaultDependencies in
  # [Unit] (the 2026-06-12 ordering-cycle lesson), runs while the pool is
  # still mounted.
  systemd.services."session-checkpoint-shutdown" = lib.mkIf (enabled && shutdownCheckpoint) {
    description = "Final session checkpoint at shutdown/reboot — a snapshot in disk, every time";
    wantedBy = [ "shutdown.target" ];
    before   = [ "shutdown.target" "umount.target" ];
    unitConfig = {
      DefaultDependencies = false;
    };
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${sessionCheckpointScript}/bin/session-checkpoint shutdown";
    };
  };

  # HIBERNATE MUST ALSO SAVE A BTRFS SNAPSHOT (2026-06-27). Hibernate does not
  # pass through shutdown.target, so session-checkpoint-shutdown never fires on
  # a hibernate trigger. This unit is ordered Before=systemd-hibernate.service
  # (the single funnel every hibernate path goes through: manual `systemctl
  # hibernate`, the battery-watchdog critical hibernate, and reboot-with-session
  # which calls `systemctl hibernate`), so a fresh file snapshot lands just
  # before the RAM image is written. TimeoutStartSec bounds it: a stuck snapshot
  # can NEVER block a battery-critical hibernate (the snapshot is CoW + idle-IO,
  # normally sub-second; the bound is pure safety).
  systemd.services."session-checkpoint-hibernate" = lib.mkIf (enabled && hibernateCheckpoint) {
    description = "Pre-hibernate session checkpoint — btrfs snapshot of ${srcSubvol} before the RAM image is written";
    wantedBy = [ "systemd-hibernate.service" ];
    before   = [ "systemd-hibernate.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = false;
      TimeoutStartSec = "30s";
      Nice                = 19;
      IOSchedulingClass   = "idle";
      ExecStart = "${sessionCheckpointScript}/bin/session-checkpoint hibernate";
    };
  };

  environment.systemPackages = lib.mkIf (enabled && rebootWithSessionEnabled) [
    rebootWithSession
  ];
}
