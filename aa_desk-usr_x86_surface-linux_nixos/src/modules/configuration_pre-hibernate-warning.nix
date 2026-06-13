# Pre-hibernate gate + warning — universal intercept of every hibernation path.
#
# WHY THIS EXISTS
# ───────────────
# Hibernation can be triggered by many independent paths on this host:
#   - battery-watchdog (configuration_system-protection-battery.nix)
#   - UPower.criticalPowerAction = "Hibernate"
#   - KDE Plasma idle policy (PowerDevil [SuspendAndShutdown])
#   - systemd-logind (lid / power-key, if ever set to hibernate)
#   - Manual `systemctl hibernate`
#
# All of them ultimately invoke `systemd-hibernate.service`. By injecting
# ExecStartPre= on that service we get ONE choke point that:
#   1. PREFLIGHT (post-2026-05-15): verifies hibernate invariants and REFUSES
#      to hibernate if any are violated (exit 1 → ExecStart never runs).
#   2. PREWARN: logs intent to journal, broadcasts via wall, sends desktop
#      notifications, then sleeps `delay_minutes` minutes before letting
#      ExecStart proceed.
#
# DATA-DRIVEN: every knob (delay, channels, cancel command) lives in
# cloud-data-power.json under the `pre_hibernate_warning` block. The invariant
# gate cross-checks against aa_bootloader/src/boot.json::swap_hibernate.
{ config, pkgs, lib, ... }:

let
  pwrJson  = builtins.fromJSON (builtins.readFile ./cloud-data-power.json);
  warn     = pwrJson.pre_hibernate_warning or {
    enabled = false;
    delay_minutes = 0;
    cancel_command = "sudo systemctl stop systemd-hibernate.service";
    channels = { journal = false; wall = false; notify_send = false; };
  };

  enabled  = warn.enabled or false;
  # delay_seconds is the canonical knob (owner wants a 30s gate, not minutes).
  # Back-compat: fall back to delay_minutes*60 if only the old field exists.
  delaySec = warn.delay_seconds or ((warn.delay_minutes or 0) * 60);
  cancel   = warn.cancel_command or "sudo systemctl stop systemd-hibernate.service";
  ch       = warn.channels or {};

  chJournal     = ch.journal or false;
  chWall        = ch.wall or false;
  chNotifySend  = ch.notify_send or false;
  chDialogCenter = ch.dialog_center or false;

  # SoT for swap/resume invariants (cross-checked at hibernate time)
  bootCfg      = builtins.fromJSON (builtins.readFile ./boot.json);
  swapfilePath = bootCfg.swap_hibernate.swapfile;
  resumeDev    = bootCfg.swap_hibernate.resume_device;

  # ───── Pre-flight correctness gate (POST-INCIDENT 2026-05-15) ─────
  hibernatePreflight = pkgs.writeShellApplication {
    name = "hibernate-preflight";
    runtimeInputs = with pkgs; [ coreutils util-linux findutils gawk libnotify e2fsprogs ];
    text = ''
      SWAP=${lib.escapeShellArg swapfilePath}
      RESUME=${lib.escapeShellArg resumeDev}

      die() {
        local msg="REFUSED hibernate: $1"
        ${pkgs.util-linux}/bin/logger -t hibernate-preflight -p user.crit "$msg"
        echo "$msg" | ${pkgs.util-linux}/bin/wall -n 2>/dev/null || true
        for udir in /run/user/*; do
          [ -d "$udir" ] || continue
          uid=$(${pkgs.coreutils}/bin/basename "$udir")
          user=$(${pkgs.gawk}/bin/awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
          [ -n "$user" ] || continue
          bus="$udir/bus"
          [ -S "$bus" ] || continue
          ${pkgs.util-linux}/bin/runuser -u "$user" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="$udir" \
            ${pkgs.libnotify}/bin/notify-send -u critical -a Power \
              "Hibernation REFUSED" "$1" 2>/dev/null || true
        done
        exit 1
      }

      # 1. Swapfile is on ext4 (or xfs) — never on btrfs (see 2026-05-15 incident).
      SWAPFS=$(${pkgs.util-linux}/bin/findmnt -no FSTYPE -T "$SWAP" 2>/dev/null) \
        || die "swapfile $SWAP not on any mounted FS"
      case "$SWAPFS" in
        ext4|xfs) ;;
        btrfs)    die "swapfile is on btrfs — see incident 2026-05-15" ;;
        *)        die "swapfile is on unsupported fs ($SWAPFS)" ;;
      esac

      # 2. resume_device is reachable and is NOT the pool.
      case "$RESUME" in
        /dev/mapper/pool|/dev/mapper/luks-*)
          die "resume_device $RESUME is on the btrfs pool (forbidden post-2026-05-15)" ;;
      esac
      RESOLVED=$(${pkgs.coreutils}/bin/readlink -f "$RESUME" 2>/dev/null) \
        || die "resume device $RESUME does not resolve"
      [ -b "$RESOLVED" ] || die "resume device $RESUME ($RESOLVED) is not a block device"

      # 3. swsusp signature in the SWAP HEADER is SWAPSPACE2 (no stale image).
      #    The swap header lives in the FIRST PAGE OF THE SWAPFILE — the 10-byte
      #    magic sits at offset (pagesize-10)=4086. It is NOT at offset 0 of the
      #    backing device: that is the ext4 superblock. Reading $RESOLVED here
      #    was the 2026-06-13 regression that refused EVERY hibernation (same
      #    device-vs-swapfile confusion class as the 2026-06-12 p5 incident).
      #    SWAPSPACE2 = clean swap, no pending image. S1SUSPEND = image present.
      SIG=$(${pkgs.coreutils}/bin/dd if="$SWAP" bs=1 skip=4086 count=10 2>/dev/null)
      case "$SIG" in
        SWAPSPACE2) ;;
        S1SUSPEND*) die "stale hibernate signature (S1SUSPEND) in $SWAP — refusing to overwrite. Run: sudo swapoff $SWAP && sudo mkswap $SWAP && sudo swapon $SWAP" ;;
        *)          die "no valid swap signature in $SWAP header (got '$SIG') — run: sudo mkswap $SWAP" ;;
      esac

      # 4. Pool-witness check: if the pool was mounted by something other than
      #    NixOS since last clean unmount, RAM-state-of-pool is stale.
      WITNESS_DISK=/mnt/shared/.pool-witness/id
      WITNESS_RUN=/run/pool-witness/current-mount.id
      if [ -r "$WITNESS_RUN" ]; then
        CUR=$(cat "$WITNESS_RUN")
        DISK=$(cat "$WITNESS_DISK" 2>/dev/null || echo "")
        if [ -n "$DISK" ] && [ "$CUR" != "$DISK" ]; then
          die "pool witness mismatch (runtime=$CUR disk=$DISK) — pool was modified out-of-band this session"
        fi
      fi

      ${pkgs.util-linux}/bin/logger -t hibernate-preflight -p user.info \
        "preflight ok (swapfs=$SWAPFS, resume=$RESUME, header=SWAPSPACE2)"
    '';
  };

  # ───── Emergency cancel commands — installed in $PATH ─────
  hibernateCancel = pkgs.writeShellApplication {
    name = "hibernate-cancel";
    runtimeInputs = with pkgs; [ systemd util-linux ];
    text = ''
      ${pkgs.systemd}/bin/systemctl stop systemd-hibernate.service 2>&1 || true
      ${pkgs.systemd}/bin/systemctl reset-failed systemd-hibernate.service 2>&1 || true
      ${pkgs.util-linux}/bin/logger -t hibernate-cancel -p daemon.warning \
        "Hibernate cancelled by $(${pkgs.coreutils}/bin/whoami)"
      echo "[hibernate-cancel] systemd-hibernate.service stopped."
      ${pkgs.systemd}/bin/systemctl is-active systemd-hibernate.service || true
    '';
  };

  hibernateEmergencyStop = pkgs.writeShellApplication {
    name = "hibernate-emergency-stop";
    runtimeInputs = with pkgs; [ systemd util-linux ];
    text = ''
      ${pkgs.systemd}/bin/systemctl stop systemd-hibernate.service 2>&1 || true
      ${pkgs.systemd}/bin/systemctl reset-failed systemd-hibernate.service 2>&1 || true
      ${pkgs.systemd}/bin/systemctl stop battery-watchdog.timer battery-watchdog.service 2>&1 || true
      ${pkgs.util-linux}/bin/logger -t hibernate-cancel -p daemon.warning \
        "EMERGENCY-STOP: hibernate cancelled + watchdog stopped by $(${pkgs.coreutils}/bin/whoami)"
      echo "[hibernate-emergency-stop] systemd-hibernate.service + battery-watchdog stopped."
      ${pkgs.systemd}/bin/systemctl is-active systemd-hibernate.service battery-watchdog.timer || true
    '';
  };

  prewarn = pkgs.writeShellApplication {
    name = "hibernate-prewarn";
    runtimeInputs = with pkgs; [ coreutils util-linux libnotify gawk yad ];
    text = ''
      DELAY_SEC=${toString delaySec}
      CANCEL_CMD=${lib.escapeShellArg cancel}
      MSG="System will HIBERNATE in $DELAY_SEC second(s). To CANCEL run: $CANCEL_CMD"

      ${lib.optionalString chJournal ''
        echo "[hibernate-prewarn] $MSG"
        ${pkgs.util-linux}/bin/logger -t hibernate-prewarn -p daemon.warning "$MSG" || true
      ''}

      ${lib.optionalString chWall ''
        # Broadcast to every terminal (tty + pty) with the inline cancel command.
        echo "$MSG" | ${pkgs.util-linux}/bin/wall -n || true
      ''}

      ${lib.optionalString chNotifySend ''
        for udir in /run/user/*; do
          [ -d "$udir" ] || continue
          uid=$(${pkgs.coreutils}/bin/basename "$udir")
          user=$(${pkgs.gawk}/bin/awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
          [ -n "$user" ] || continue
          bus="$udir/bus"
          [ -S "$bus" ] || continue
          ${pkgs.util-linux}/bin/runuser -u "$user" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="$udir" \
            ${pkgs.libnotify}/bin/notify-send \
              -u critical -t $((DELAY_SEC * 1000)) -a "Power" \
              "Hibernation in $DELAY_SEC second(s)" "$MSG" || true
        done
      ''}

      # ───── centered DARK modal with a live countdown + copyable cancel CLI ─────
      # notify-send (above) is only a corner toast; this yad dialog is the
      # centered, dark-themed, attention-grabbing popup the owner asked for:
      #   • --timeout + --timeout-indicator = a visible shrinking countdown bar
      #   • GTK_THEME=Adwaita:dark           = dark mode
      #   • <tt>…</tt> + --selectable-labels = the cancel command in monospace,
      #                                        selectable to copy & paste
      # It also serves as the countdown wait. yad exit codes:
      #   "Hibernate now" → 0  → proceed immediately
      #   "Cancel"        → 1  → abort hibernation (ExecStartPre exits 1)
      #   timed out       → 70 → proceed (the countdown elapsed)
      #   could not display → fast non-zero → fall through to plain sleep
      GUI_TEXT="<span size=\"xx-large\" weight=\"bold\">⚠  Hibernation</span>

The session is about to be saved to disk and the machine powered off.

<b>To cancel from a terminal, copy &amp; paste:</b>
<tt><big>$CANCEL_CMD</big></tt>

<i>…or press “Cancel (stay awake)” below.</i>"
      DID_WAIT=0
      ${lib.optionalString chDialogCenter ''
        for udir in /run/user/*; do
          [ -d "$udir" ] || continue
          uid=$(${pkgs.coreutils}/bin/basename "$udir")
          user=$(${pkgs.gawk}/bin/awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
          [ -n "$user" ] || continue
          bus="$udir/bus"
          [ -S "$bus" ] || continue
          # Discover the Wayland socket for this session (KDE Plasma 6 = wayland-0).
          wl=$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/ls "$udir"/wayland-[0-9] 2>/dev/null | ${pkgs.coreutils}/bin/head -1)" 2>/dev/null || echo wayland-0)
          start=$(${pkgs.coreutils}/bin/date +%s)
          set +e
          # Hard backstop timeout (DELAY+5) in case yad itself hangs; yad's own
          # --timeout drives the visible countdown and exits 70 when it lapses.
          ${pkgs.util-linux}/bin/runuser -u "$user" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            XDG_RUNTIME_DIR="$udir" \
            WAYLAND_DISPLAY="''${wl:-wayland-0}" \
            GDK_BACKEND="wayland,x11" \
            GTK_THEME="Adwaita:dark" \
            GTK_APPLICATION_PREFER_DARK_THEME=1 \
            ${pkgs.coreutils}/bin/timeout $((DELAY_SEC + 5)) \
            ${pkgs.yad}/bin/yad \
              --title="Hibernation" \
              --window-icon=battery-caution --image=battery-caution \
              --text="$GUI_TEXT" --text-align=center --selectable-labels \
              --timeout="$DELAY_SEC" --timeout-indicator=bottom \
              --center --on-top --width=560 --borders=20 \
              --button="Cancel (stay awake)!process-stop:1" \
              --button="Hibernate now!system-suspend-hibernate:0"
          rc=$?
          set -e
          elapsed=$(( $(${pkgs.coreutils}/bin/date +%s) - start ))
          if [ "$rc" = "1" ]; then
            ${pkgs.util-linux}/bin/logger -t hibernate-prewarn -p daemon.warning \
              "user $user CANCELLED hibernation via centered dialog"
            exit 1
          fi
          # Count this as the countdown wait only if the dialog really ran
          # (timed out=70, or a button=0) rather than failing to display.
          if [ "$elapsed" -ge 2 ] || [ "$rc" = "0" ] || [ "$rc" = "70" ]; then DID_WAIT=1; fi
          break
        done
      ''}

      # Fallback wait when no centered dialog ran (headless / display unavailable
      # / dialog_center off) — the toast + terminal broadcast still gave notice.
      if [ "$DID_WAIT" = "0" ] && [ "$DELAY_SEC" -gt 0 ]; then
        ${pkgs.coreutils}/bin/sleep "$DELAY_SEC"
      fi
    '';
  };

in
{
  # The hibernate gate runs unconditionally — preflight catches invariant
  # violations even when the UX countdown is disabled.
  systemd.services."systemd-hibernate" = {
    serviceConfig.ExecStartPre =
      [ "${hibernatePreflight}/bin/hibernate-preflight" ]
      ++ lib.optional enabled "${prewarn}/bin/hibernate-prewarn";
    serviceConfig.TimeoutStartSec = toString (delaySec + 600);
  };

  environment.systemPackages = [
    hibernateCancel          # `hibernate-cancel`
    hibernateEmergencyStop   # `hibernate-emergency-stop`
  ];
}
