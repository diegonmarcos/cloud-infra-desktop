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
    script = ''
      set -u
      ROOT=${lib.escapeShellArg btrfsRoot}
      SRC="$ROOT/${srcSubvol}"
      DEST_DIR="$ROOT/${snapDir}"
      KEEP=${toString retention}

      # Pool not mounted (rescue context, mid-recovery) → skip, never fail.
      if ! btrfs subvolume show "$SRC" >/dev/null 2>&1; then
        logger -t session-checkpoint -p user.warning \
          "source subvol $SRC not available — skipping checkpoint"
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

      TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
      btrfs subvolume snapshot -r "$SRC" "$DEST_DIR/$TS" >/dev/null
      logger -t session-checkpoint -p user.info \
        "session checkpoint written: $DEST_DIR/$TS"

      # Prune: keep the newest $KEEP (timestamp names sort chronologically).
      ls -1 "$DEST_DIR" | sort | head -n -"$KEEP" | while read -r old; do
        btrfs subvolume delete "$DEST_DIR/$old" >/dev/null \
          && logger -t session-checkpoint -p user.info "pruned checkpoint $old"
      done
    '';
  };
}
