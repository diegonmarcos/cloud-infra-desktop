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
#   System (CPU/Mem/Disk/Net, one consolidated widget) │ SystemTray · Clock
#
# 2026-07-04: was 7 separate org.kde.plasma.systemmonitor widget INSTANCES
# (CPU%, Cores, Mem%, Disk, DiskBars, Disk%, Net). Root-caused live via the
# plasma scripting console (qdbus org.kde.plasmashell evaluateScript) + the
# actual KSysGuard QML source (CompactRepresentation.qml/main.qml): only the
# FIRST systemmonitor widget instance in a containment ever renders its
# sensor data — a KDE backend bug in the sensor-face controller, confirmed by
# comparing byte-identical Configuration blocks between a working and a
# blank instance (no config difference). Fix: ONE widget instance carrying
# ALL sensors (KSysGuard supports multiple sensors per widget natively) —
# confirmed working live before committing. Trade-off: one shared chartFace
# for all sensors (textonly), so the per-core bars / separate line-and-bar
# disk views are gone; still shows every core's aggregate via cpu/all/usage.
#
# PSI (pressure some/full) is NOT here: KSystemStats has no /proc/pressure
# sensor, so a stock panel widget cannot show it. PSI lives in
# Cloud-Terminal → System Performance (which reads /proc/pressure directly).
{ config, lib, pkgs, ... }:
let
  data      = builtins.fromJSON (builtins.readFile ./bottom-panel.json);
  launchers = map (d: "applications:${d}.desktop") data.launchers;
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

        # ── ONE consolidated system-monitor widget (see 2026-07-04 note above) ──
        {
          systemMonitor = {
            title = "System";
            displayStyle = "org.kde.ksysguard.textonly";
            # 2s sensor rate (default 500ms). Top-level plain key → written at
            # the [Configuration] ROOT group, where SensorFaceController reads
            # updateRateLimit (verified against plasma-manager
            # modules/widgets/lib.nix setWidgetSettings + live CurrentPreset).
            settings.updateRateLimit = 2000;
            # Single-char labels: 6 sensors + full words truncated the text in
            # the available panel width (confirmed live, 2026-07-04) — single
            # chars render cleanly with no truncation at this panel height.
            sensors = [
              { name = "cpu/all/usage";                color = "123,127,255"; label = "C"; }
              { name = "memory/physical/usedPercent";  color = "167,139,250"; label = "M"; }
              { name = "memory/swap/usedPercent";      color = "251,191,36";  label = "S"; }
              { name = "disk/all/usedPercent";         color = "34,211,238";  label = "D"; }
              { name = "network/all/download";         color = "74,222,128";  label = "↓"; }
              { name = "network/all/upload";           color = "232,121,249"; label = "↑"; }
            ];
          };
        }

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
