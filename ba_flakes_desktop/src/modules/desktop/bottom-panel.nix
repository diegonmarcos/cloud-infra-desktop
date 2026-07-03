# bottom-panel.nix — FULLY DECLARATIVE bottom panel (plasma-manager).
#
# Reverses the old "panel is user-managed" note in plasma.nix: the layout is
# now data-driven here + bottom-panel.json. plasma-manager recreates the panel
# on every switch (that's the declarative contract — the JSON is the source of
# truth, not the live appletsrc).
#
# Layout (left → right):
#   Kickoff · Pager(Desk1-4) │ IconTasks(Konsole, Cloud-Terminal, Dolphin,
#   QuteBrowser, Brave, Kate, Obsidian, Configs, Redroid) │ spacer │
#   CPU% · per-core bars · Mem% · Disk line · Disk bars · Disk% · Net graph │
#   SystemTray · Clock
#
# PSI (pressure some/full) is NOT here: KSystemStats has no /proc/pressure
# sensor, so a stock panel widget cannot show it. PSI lives in
# Cloud-Terminal → System Performance (which reads /proc/pressure directly).
{ config, lib, pkgs, ... }:
let
  data      = builtins.fromJSON (builtins.readFile ./bottom-panel.json);
  launchers = map (d: "applications:${d}.desktop") data.launchers;
  # plasma-manager requires a `color` (R,G,B string) on every systemMonitor sensor.
  palette = [ "123,127,255" "167,139,250" "34,211,238" "74,222,128" "251,191,36" "232,121,249" "248,113,113" "125,211,252" ];
  # Per-core CPU barchart (0..7; cores that don't exist are simply absent).
  coreSensors = map (n: { name = "cpu/cpu${toString n}/usage"; color = builtins.elemAt palette n; label = "C${toString n}"; }) (lib.range 0 7);
  mon = title: style: sensors: { systemMonitor = { inherit title sensors; displayStyle = style; }; };
in
{
  programs.plasma.panels = [
    {
      location = "bottom";
      height = data.height;
      floating = false;
      widgets = [
        { name = "org.kde.plasma.kickoff"; config.General.icon = "nix-snowflake-white"; }
        { name = "org.kde.plasma.pager"; }
        "org.kde.plasma.marginsseparator"
        { name = "org.kde.plasma.icontasks"; config.General.launchers = launchers; }
        "org.kde.plasma.panelspacer"

        # ── System monitors (KSystemStats sensors; each needs color + label) ──
        (mon "CPU%"     "org.kde.ksysguard.textonly"  [ { name = "cpu/all/usage"; color = "123,127,255"; label = "CPU"; } ])            # cpu usage %
        (mon "Cores"    "org.kde.ksysguard.barchart"  coreSensors)                                                                      # per-core vertical bars
        (mon "Mem%"     "org.kde.ksysguard.textonly"  [ { name = "memory/physical/usedPercent"; color = "167,139,250"; label = "Mem"; } ]) # mem usage %
        (mon "Disk"     "org.kde.ksysguard.linechart" [ { name = "disk/all/usedPercent"; color = "34,211,238"; label = "Disk"; } ])     # disk usage graphic
        (mon "DiskBars" "org.kde.ksysguard.barchart"  [ { name = "disk/all/usedPercent"; color = "34,211,238"; label = "Disk"; } ])     # disk horizontal bars
        (mon "Disk%"    "org.kde.ksysguard.textonly"  [ { name = "disk/all/usedPercent"; color = "34,211,238"; label = "Disk"; } ])     # disk usage %
        (mon "Net"      "org.kde.ksysguard.linechart" [ { name = "network/all/download"; color = "34,211,238";  label = "↓"; }
                                                        { name = "network/all/upload";   color = "232,121,249"; label = "↑"; } ])        # network graphic

        "org.kde.plasma.marginsseparator"
        { name = "org.kde.plasma.systemtray"; }
        {
          digitalClock = {
            time.format = "24h";
            date = { enable = true; format = "isoDate"; position = "belowTime"; };
            calendar.firstDayOfWeek = "monday";
          };
        }
      ];
    }
  ];
}
