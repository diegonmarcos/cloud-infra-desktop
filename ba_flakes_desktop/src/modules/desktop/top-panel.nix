# top-panel.nix — FULLY DECLARATIVE top panel (plasma-manager).
#
# 2026-08-11: nine widgets — four com.diegonmarcos.watchdog summary widgets
# (storage, mem, cpu, network), a panelspacer, the digital clock, a second
# panelspacer, then two more watchdog widgets (guard, psi — psi is
# deliberately the rightmost widget on the panel). Data lives in
# top-panel.json, including the widget order; this file only renders it
# generically (map over data.widgets), exactly like bottom-panel.nix — it
# has no hardcoded widget count or index, so the widget list can grow or
# shrink purely by editing the JSON. See top-panel.json's own _comment for
# the full history (this replaced fourteen org.kde.plasma.systemmonitor
# instances) and plasma-panel-repair.json for why four of these six
# watchdog widgets need a post-activation repair pass to actually appear.
#
# Each widget is emitted in plasma-manager's raw form { name; config; } —
# config mirrors the appletsrc [Configuration][<group>] sections verbatim.
# Duplicate-accumulation is prevented by programs.plasma.overrideConfig =
# true (set in plasma.nix): plasma-manager regenerates the whole panel set
# from THIS declaration on every switch, so nothing can pile up in the live
# appletsrc anymore.
{ config, lib, pkgs, ... }:
let
  data = builtins.fromJSON (builtins.readFile ./top-panel.json);
  toWidget = w:
    if w ? name then { inherit (w) name; config = w.config; }
    else if w.kind == "digitalclock" then { name = "org.kde.plasma.digitalclock"; } // (if w ? config then { inherit (w) config; } else {})
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
