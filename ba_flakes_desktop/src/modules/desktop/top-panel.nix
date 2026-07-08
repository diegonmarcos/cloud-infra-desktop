# top-panel.nix — FULLY DECLARATIVE top panel (plasma-manager).
#
# Captured from the live layout on 2026-07-08 (user-blessed "source of truth"):
# 15 widgets — a monitor cluster (Disk/CPU/Cores/Mem/Write-Read + two PSI
# pressure widgets) around a centre clock. Data lives in top-panel.json;
# this file only renders it, exactly like bottom-panel.nix.
#
# WHY the original plugin variants are preserved (systemmonitor.cpu /
# .cpucore / .memory / .diskusage rather than all-generic): KSysGuard has a
# backend bug where only the FIRST generic org.kde.plasma.systemmonitor in a
# containment renders its sensors (documented in bottom-panel.nix). Keeping
# the specific variants sidesteps it — every widget renders.
#
# Each widget is emitted in plasma-manager's raw form { name; config; } where
# config mirrors the appletsrc [Configuration][<group>] sections verbatim
# (Appearance / Sensors / SensorColors / SensorLabels). Duplicate-accumulation
# is prevented by programs.plasma.overrideConfig = true (set in plasma.nix):
# plasma-manager regenerates the whole panel set from THIS declaration on every
# switch, so nothing can pile up in the live appletsrc anymore.
{ config, lib, pkgs, ... }:
let
  data = builtins.fromJSON (builtins.readFile ./top-panel.json);
  toWidget = w:
    if w ? name then { inherit (w) name; config = w.config; }
    else if w.kind == "digitalclock" then { name = "org.kde.plasma.digitalclock"; }
    else "org.kde.plasma.${w.kind}";     # panelspacer et al.
in
{
  programs.plasma.panels = [
    {
      location = data.location;
      height = data.height;
      floating = false;
      widgets = map toWidget data.widgets;
    }
  ];
}
