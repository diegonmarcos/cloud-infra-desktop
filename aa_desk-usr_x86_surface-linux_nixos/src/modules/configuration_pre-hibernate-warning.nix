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
  # Script lives in hibernate-preflight.sh (inline scripts inside nix modules
  # are forbidden here). Fully runtime-data-driven: swapfile path + resume
  # device are read at RUNTIME from /etc/cloud-data/boot.json via jq —
  # nothing is baked in by Nix interpolation. swapfilePath/resumeDev above
  # are still computed here too (from the same source JSON) purely so this
  # module's own file stays useful for any future build-time cross-checks;
  # the runtime script independently re-reads and validates via jq.
  hibernatePreflight = pkgs.writeShellApplication {
    name = "hibernate-preflight";
    runtimeInputs = with pkgs; [ coreutils util-linux findutils gawk libnotify e2fsprogs jq ];
    text = builtins.readFile ./hibernate-preflight.sh;
  };

  # ───── Emergency cancel commands — installed in $PATH ─────
  hibernateCancel = pkgs.writeShellApplication {
    name = "hibernate-cancel";
    runtimeInputs = with pkgs; [ systemd util-linux coreutils ];
    text = builtins.readFile ./hibernate-cancel.sh;
  };

  hibernateEmergencyStop = pkgs.writeShellApplication {
    name = "hibernate-emergency-stop";
    runtimeInputs = with pkgs; [ systemd util-linux coreutils ];
    text = builtins.readFile ./hibernate-emergency-stop.sh;
  };

  # Script lives in hibernate-prewarn.sh. Fully runtime-data-driven: delay,
  # cancel command and every channel toggle are read at RUNTIME from
  # /etc/cloud-data/power.json (pre_hibernate_warning block) via jq —
  # nothing is baked in by Nix interpolation (the lib.optionalString
  # per-channel blocks from the old inline version are now plain shell
  # `if` gates on jq-read values, same pattern as battery-watchdog.sh's
  # voters).
  prewarn = pkgs.writeShellApplication {
    name = "hibernate-prewarn";
    runtimeInputs = with pkgs; [ coreutils util-linux libnotify gawk yad jq ];
    text = builtins.readFile ./hibernate-prewarn.sh;
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

  # hibernate-prewarn.sh and hibernate-preflight.sh read their config at
  # RUNTIME from these paths via jq. Neither cloud-data-power.json nor
  # boot.json was previously deployed to /etc by any other module (checked:
  # only disk-protection.json, system-protection.json and
  # battery-protection.json are declared elsewhere) — this is the one place
  # that declares both.
  environment.etc."cloud-data/power.json".source = ./cloud-data-power.json;
  environment.etc."cloud-data/boot.json".source = ./boot.json;
}
