# Pre-hibernate warning — universal intercept of every hibernation path
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
# All of them ultimately invoke `systemd-hibernate.service`. By injecting an
# `ExecStartPre=` on that service, we get ONE choke point that:
#   1. Logs the intent to the journal
#   2. Broadcasts via `wall` to every TTY
#   3. Sends a desktop notification (`notify-send`) to each logged-in user
#   4. Sleeps `delay_minutes` minutes before letting `ExecStart` proceed
#
# Cancelling: `sudo systemctl stop systemd-hibernate.service` during the
# countdown aborts the ExecStartPre → ExecStart never runs → no hibernate.
#
# DATA-DRIVEN: every knob (delay, channels, cancel command) lives in
# cloud-data-power.json under the `pre_hibernate_warning` block.
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
  delayMin = warn.delay_minutes or 0;
  cancel   = warn.cancel_command or "sudo systemctl stop systemd-hibernate.service";
  ch       = warn.channels or {};

  chJournal    = ch.journal or false;
  chWall       = ch.wall or false;
  chNotifySend = ch.notify_send or false;

  # ───── Emergency cancel command — installed in $PATH ─────
  # `hibernate-cancel`  → aborts any in-progress hibernate countdown.
  # `hibernate-emergency-stop` → also stops battery-watchdog so it cannot re-fire.
  hibernateCancel = pkgs.writeShellApplication {
    name = "hibernate-cancel";
    runtimeInputs = with pkgs; [ systemd util-linux ];
    text = ''
      # Stops the in-progress hibernate (during the prewarn countdown). Idempotent.
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
      # Cancels any in-progress hibernate AND stops the battery-watchdog timer
      # so it cannot re-fire this boot. Re-enabled on next reboot or `systemctl
      # start battery-watchdog.timer`.
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
    runtimeInputs = with pkgs; [ coreutils util-linux libnotify gawk ];
    text = ''
      # DELAY_MIN baked in from cloud-data-power.json (data-driven).
      DELAY_MIN=${toString delayMin}
      CANCEL_CMD=${lib.escapeShellArg cancel}
      MSG="System will HIBERNATE in $DELAY_MIN minute(s). Cancel: $CANCEL_CMD"

      ${lib.optionalString chJournal ''
        # Goes to the journal via stdout (systemd captures it under the unit)
        # AND to syslog with a dedicated tag so journalctl -t hibernate-prewarn works.
        echo "[hibernate-prewarn] $MSG"
        ${pkgs.util-linux}/bin/logger -t hibernate-prewarn -p daemon.warning "$MSG" || true
      ''}

      ${lib.optionalString chWall ''
        # Broadcast to every TTY (root sessions + login shells).
        echo "$MSG" | ${pkgs.util-linux}/bin/wall -n || true
      ''}

      ${lib.optionalString chNotifySend ''
        # Desktop notification per logged-in user via their D-Bus session.
        for udir in /run/user/*; do
          [ -d "$udir" ] || continue
          uid=$(${pkgs.coreutils}/bin/basename "$udir")
          # Resolve uid → user via /etc/passwd (avoids glibc nss tooling that's
          # awkward to reach from a writeShellApplication runtimeInputs).
          user=$(${pkgs.gawk}/bin/awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
          [ -n "$user" ] || continue
          bus="$udir/bus"
          [ -S "$bus" ] || continue
          # urgency=critical so KDE/GNOME show it persistently
          ${pkgs.util-linux}/bin/runuser -u "$user" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            XDG_RUNTIME_DIR="$udir" \
            ${pkgs.libnotify}/bin/notify-send \
              -u critical \
              -t $((DELAY_MIN * 60 * 1000)) \
              -a "Power" \
              "Hibernation in $DELAY_MIN minute(s)" \
              "$MSG" || true
        done
      ''}

      # If DELAY_MIN=0 the warning is informational only — fall through immediately.
      if [ "$DELAY_MIN" -gt 0 ]; then
        ${pkgs.coreutils}/bin/sleep $((DELAY_MIN * 60))
      fi
    '';
  };

in
{
  # Only inject the drop-in when enabled; when disabled, hibernate runs as
  # upstream defines it (no ExecStartPre).
  systemd.services."systemd-hibernate" = lib.mkIf enabled {
    serviceConfig.ExecStartPre = [
      "${prewarn}/bin/hibernate-prewarn"
    ];
    # Generous TimeoutStartSec so the countdown can elapse without systemd
    # killing the unit halfway. Default StartTimeout would race with delay_minutes.
    serviceConfig.TimeoutStartSec = toString ((delayMin * 60) + 600);
  };

  # System-wide emergency commands. Both require sudo (systemctl stop on a
  # system unit needs root), but the binaries themselves are unprivileged
  # wrappers — there's no setuid here.
  environment.systemPackages = [
    hibernateCancel          # `hibernate-cancel`
    hibernateEmergencyStop   # `hibernate-emergency-stop`
  ];
}
