# Power policy — UPower thresholds, logind power-button handler, kernel sleep cmdline.
#
# WHY THIS EXISTS
# ───────────────
# Energy/battery rules used to be siloed in three places (host security, KDE
# PowerDevil, battery-watchdog) with hardcoded thresholds in each. That risks
# drift and creates races where two layers fire at exactly the same percentage.
# This module is the host-side consumer of cloud-data-power.json (single SoT).
#
# Configures (via proper NixOS module options — never raw /etc writes):
#   - services.upower.{percentageLow,percentageCritical,percentageAction,
#                       criticalPowerAction,usePercentageForPolicy,...}
#                                ← thresholds.* + actions.critical
#   - services.logind.powerKey   ← events.power_button.short
#   - boot.kernelParams          ← kernel.mem_sleep_default (force S3 over s2idle)
#   - systemd.sleep.extraConfig  ← actions.never (HARD systemd-level suspend ban)
#
# WHY THE systemd.sleep BLOCK (2026-07-16)
# ────────────────────────────────────────
# mem_sleep_default=deep was the ONLY anti-suspend lever, on the theory that a
# rogue suspend would hit S3 and "fail fast". On the SP8 that theory is false:
# ACPI advertises only S0/S4/S5 (no S3), so /sys/power/mem_sleep exposes s2idle
# ONLY and the kernel silently downgrades `deep` → s2idle. A `systemctl suspend`
# from any path with no consumer-side guard (KDE Sleep menu, autosuspend) then
# half-sleeps in s2idle and never resumes → forced reboot (observed 2026-07-11).
# logind/UPower/PowerDevil are already guarded, but nothing enforced the ban at
# the systemd layer. AllowSuspend=no makes systemd-sleep itself refuse every
# suspend-family mode while keeping AllowHibernation=yes (critical action +
# reboot-with-session both need S4). This is the invariant made real.
#
# Lid handling lives in configuration_security.nix (logind.lidSwitch family).
# PowerDevil / kscreenlockerrc lives in ba_flakes_desktop home-manager flake.
{ config, pkgs, lib, ... }:

let
  pwrJson = builtins.fromJSON (builtins.readFile ./cloud-data-power.json);
  t       = pwrJson.thresholds;
  evt     = pwrJson.events;
  banned  = pwrJson.actions.never;

  # Hard guard: refuse any banned verb (sleep/suspend/s2idle).
  guard = name: v:
    if builtins.elem v banned
    then throw "configuration_power: ${name}=${v} is in actions.never (Surface S3 is broken)"
    else v;

  # Map JSON action verb to UPower's CriticalPowerAction enum.
  # NixOS option services.upower.criticalPowerAction accepts: "HybridSleep",
  # "Hibernate", "PowerOff" (case-sensitive).
  upowerAction =
    let v = pwrJson.actions.critical;
    in if v == "hibernate" then "Hibernate"
       else if v == "poweroff" then "PowerOff"
       else if v == "hybrid-sleep" then "HybridSleep"
       else throw "configuration_power: actions.critical=${v} is not a valid UPower verb";

  powerKey = guard "events.power_button.short" evt.power_button.short;

  memSleep = pwrJson.kernel.mem_sleep_default or "deep";

  # Suspend is banned iff the SoT never-list names any suspend-family verb.
  # (mem_sleep_default can't enforce this on the SP8 — S3 doesn't exist, so the
  # kernel downgrades `deep` → s2idle. systemd-sleep is the real enforcement.)
  suspendBanned = lib.any (v: builtins.elem v banned)
    [ "sleep" "suspend" "s2idle" "hybrid-sleep" "suspend-then-hibernate" ];
  noYes = b: if b then "no" else "yes";
in

{
  # ───── UPower thresholds + critical action ─────
  # PercentageAction = critical_pct so UPower's own action path fires at the
  # same point as PowerDevil. Both depend on the SAM data path (Tier 1). The
  # battery-watchdog (cloud-data-battery-protection.json) is the SAM-independent
  # Tier 2 — see configuration_system-protection-battery.nix.
  services.upower.enable                = true;
  services.upower.usePercentageForPolicy = true;
  services.upower.percentageLow         = t.low_pct;
  services.upower.percentageCritical    = t.critical_pct;
  services.upower.percentageAction      = t.critical_pct;
  services.upower.criticalPowerAction   = upowerAction;

  # ───── Power button → lock (tablet ergonomics; buttons get bumped) ─────
  services.logind.powerKey          = powerKey;
  services.logind.powerKeyLongPress = "ignore";

  # ───── Prefer S3-deep over s2idle (best-effort cmdline hint) ─────
  # Kept as a hint, but on the SP8 the kernel exposes s2idle ONLY and ignores
  # this — see the header note. Real enforcement is the systemd.sleep block below.
  boot.kernelParams = [ "mem_sleep_default=${memSleep}" ];

  # ───── HARD suspend ban at the systemd-sleep layer ─────
  # /etc/systemd/sleep.conf. systemd-sleep refuses any mode set to Allow*=no,
  # so `systemctl suspend` / logind auto-suspend / KDE Sleep all fail cleanly
  # instead of s2idle-hanging. Hibernation stays allowed (critical-battery
  # action + `reboot-with-session` both need S4; the session-checkpoint runtime
  # drop-in only overrides HibernateMode, never these Allow* keys).
  systemd.sleep.extraConfig = ''
    AllowSuspend=${noYes suspendBanned}
    AllowHybridSleep=${noYes suspendBanned}
    AllowSuspendThenHibernate=${noYes suspendBanned}
    AllowHibernation=yes
  '';
}
