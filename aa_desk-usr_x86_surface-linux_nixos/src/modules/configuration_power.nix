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

  # ───── Force S3-deep instead of s2idle ─────
  # If anything ever does try to suspend (against policy), it goes to S3 and
  # fails fast rather than half-sleeping in s2idle forever.
  boot.kernelParams = [ "mem_sleep_default=${memSleep}" ];
}
