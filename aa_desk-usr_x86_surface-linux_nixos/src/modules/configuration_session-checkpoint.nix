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
  btrfsRoot = cp.btrfs_root;
  srcSubvol = cp.source_subvol;
  snapDir   = cp.snapshot_dir;
  interval  = cp.interval_minutes;
  retention = cp.retention_count;

  shutdownCheckpoint = (cfg.shutdown_checkpoint or {}).enabled or false;
  rebootWithSessionEnabled = (cfg.reboot_with_session or {}).enabled or false;

  # Shared checkpoint body — used by the periodic timer service AND the
  # shutdown/reboot hook (REBOOT MUST ALWAYS SAVE A SNAPSHOT IN DISK).
  mkCheckpointScript = tag: ''
    set -u
    ROOT=${lib.escapeShellArg btrfsRoot}
    SRC="$ROOT/${srcSubvol}"
    DEST_DIR="$ROOT/${snapDir}"
    KEEP=${toString retention}

    # Pool not mounted (rescue context, mid-recovery) → skip, never fail.
    if ! btrfs subvolume show "$SRC" >/dev/null 2>&1; then
      logger -t session-checkpoint -p user.warning \
        "source subvol $SRC not available — skipping ${tag} checkpoint"
      exit 0
    fi

    # Parent of the snapshot tree must be a subvolume too (so checkpoints
    # are excluded from any future snapshot of the top level). Create the
    # hierarchy on first run.
    PARENT="$ROOT/$(dirname ${lib.escapeShellArg snapDir})"
    if ! btrfs subvolume show "$PARENT" >/dev/null 2>&1; then
      btrfs subvolume create "$PARENT"
    fi
    mkdir -p "$DEST_DIR"

    TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)-${tag}
    btrfs subvolume snapshot -r "$SRC" "$DEST_DIR/$TS" >/dev/null
    sync
    logger -t session-checkpoint -p user.info \
      "${tag} session checkpoint written: $DEST_DIR/$TS"

    # Prune: keep the newest $KEEP (timestamp names sort chronologically).
    ls -1 "$DEST_DIR" | sort | head -n -"$KEEP" | while read -r old; do
      btrfs subvolume delete "$DEST_DIR/$old" >/dev/null \
        && logger -t session-checkpoint -p user.info "pruned checkpoint $old"
    done
  '';

  # `sudo reboot-with-session` — the RAM-session counterpart for restarts:
  # write the full hibernate image, then REBOOT instead of powering off
  # (kernel disk-mode 'reboot' via a RUNTIME sleep.conf.d drop-in that only
  # exists for this invocation: /run is tmpfs, so a completed reboot wipes
  # it, and the battery-watchdog's critical hibernate keeps its normal
  # power-off semantics). At the boot menu: NixOS - Primary resumes the
  # session; NixOS - Fresh Desktop starts clean. For booting a NEW kernel,
  # use plain `reboot` — resuming the image returns to the old kernel by
  # design.
  rebootWithSession = pkgs.writeShellApplication {
    name = "reboot-with-session";
    runtimeInputs = with pkgs; [ systemd coreutils util-linux ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "reboot-with-session: must run as root (sudo)" >&2
        exit 1
      fi
      DROPIN_DIR=/run/systemd/sleep.conf.d
      DROPIN="$DROPIN_DIR/zz-reboot-with-session.conf"
      mkdir -p "$DROPIN_DIR"
      printf '[Sleep]\nHibernateMode=reboot\n' > "$DROPIN"
      # If hibernate is refused (no swap, masked, gate tripped), remove the
      # drop-in so a later battery-critical hibernate still powers OFF.
      # On success the machine reboots and tmpfs /run discards it anyway;
      # if the session is RESUMED later, /run came back from the image —
      # the trap fires as this script continues, cleaning it then too.
      trap 'rm -f "$DROPIN"' EXIT
      logger -t reboot-with-session "writing session image to disk, then rebooting"
      systemctl hibernate
    '';
  };
in
{
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
    };
    path = with pkgs; [ btrfs-progs coreutils util-linux ];
    script = mkCheckpointScript "periodic";
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
    };
    path = with pkgs; [ btrfs-progs coreutils util-linux ];
    script = mkCheckpointScript "shutdown";
  };

  environment.systemPackages = lib.mkIf (enabled && rebootWithSessionEnabled) [
    rebootWithSession
  ];
}
