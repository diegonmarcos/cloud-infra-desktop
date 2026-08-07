# bottom-panel.nix — FULLY DECLARATIVE bottom panel (plasma-manager).
#
# Reverses the old "panel is user-managed" note in plasma.nix: the layout is
# now data-driven here + bottom-panel.json. plasma-manager recreates the panel
# on every switch (that's the declarative contract — the JSON is the source of
# truth, not the live appletsrc).
#
# Layout (left → right):
#   Kickoff · Pager(Desk1-4) │ spacer │ IconTasks │ spacer │ Watchdog(proctable) │ TWO SystemTrays
#   (the launchers sit between two expanding spacers, so they centre)
#   No clock — it lives on the top panel only.
#
# 2026-08-07: ONE com.diegonmarcos.watchdog instance added back, mode=
# "proctable" — a sortable process table with multiple kill signals, not a
# summary-numbers duplicate of the top panel's left/right/guard instances (see
# the long-form history below for why THOSE were kept off this panel). This is
# also the plugin's FIRST addWidget() call in the bottom panel's script, so the
# "3rd-and-later same-plugin instance silently dropped" bug documented in
# plasma-panel-repair.json (which is about the TOP panel's 3rd instance,
# mode=guard) does not apply here and no repair-list entry was added for it.
#
# 2026-08-02: the system-monitor widget is gone. Its history is worth keeping
# because it explains why the replacement is not another one: it began as 7
# separate org.kde.plasma.systemmonitor INSTANCES, of which only the first ever
# rendered (a KSysGuard sensor-face controller bug, root-caused live in July via
# the plasma scripting console against the actual QML source), so it was
# consolidated into ONE instance carrying all six sensors. That was right about
# the symptom and wrong about the tool. Even one instance builds a sensor-face
# controller and a KQuickCharts scene graph inside plasmashell, and the top
# panel's fourteen of them settled at ~24% CPU and 410MB — 135MB of it QML JS
# heap — to display eight numbers. Reading /proc was never the cost:
# ksystemstats, which does it, measures 2.5%.
#
# It is now com.diegonmarcos.watchdog, which reads a snapshot my-konsole's tray
# daemon publishes every 2s and draws text. Cost stops scaling with how many
# metrics are shown. PSI finally appears in a panel too — KSystemStats has no
# /proc/pressure sensor, so no stock widget could ever display it, which is why
# the old top panel resorted to diskusage widgets pointed at pressure paths
# under titles naming something else entirely.
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

        # Spacer BEFORE the launchers as well as after. A panelspacer is
        # expanding, so one on each side splits the leftover width evenly and
        # the launcher row lands centred; with only the trailing one it was
        # pinned hard against the pager, which is the gap being complained
        # about. Centring it in icontasks' own config is not an option —
        # the applet has no such setting, the panel layout is the mechanism.
        "org.kde.plasma.panelspacer"
        { name = "org.kde.plasma.icontasks"; config.General.launchers = launchers; }
        "org.kde.plasma.panelspacer"

        # The process-table instance. Deliberately NOT mode=left/right/guard —
        # those are summary numbers already shown on the top panel, and a copy
        # here would just poll and draw the same snapshot a second time.
        # proctable is a distinct capability (sortable per-process table,
        # multiple kill signals), so one instance earns its place here.
        { name = "com.diegonmarcos.watchdog"; config.General = { mode = "proctable"; uid = data.watchdog_uid; }; }
        "org.kde.plasma.marginsseparator"

        # ── The rest of this panel carries NO other watchdog widget ──
        # top-panel.json already carries the three summary instances
        # (mode=left, mode=right, mode=guard) flanking the clock. The history
        # below is kept because it explains why the bottom panel had no
        # system monitor of ANY kind before the proctable instance above.
        #
        # ── (former) Watchdog widget — reads the snapshot, runs no sensor stack ──
        # Was ONE consolidated org.kde.plasma.systemmonitor carrying six
        # sensors, which was itself a fix for seven separate instances (only
        # the first in a containment ever rendered — a KSysGuard backend bug
        # root-caused live in July). That consolidation was right about the
        # symptom and stuck with the wrong tool: even one instance builds a
        # sensor-face controller inside plasmashell, and the top panel's
        # fourteen of them settled at ~24% CPU and 410MB for eight numbers.
        #
        # my-konsole's tray daemon already runs permanently and now samples
        # /proc once every 2s into $XDG_RUNTIME_DIR/my-konsole-watchdog.json.
        # This reads it. Cost no longer scales with how many metrics show, and
        # PSI is available at last — /proc/pressure has no KSystemStats
        # backend, so no stock widget could ever display it.

        # TWO trays, matching the live layout this file is now captured from.
        # One holds OUR eight app trays and shows them permanently; the other
        # holds KDE's own indicators and lets them auto-hide, so battery and
        # volume appear when they have something to say while nix-flakes,
        # docker, my-ai and the rest are always one click away. A single tray
        # cannot express both policies — shownItems/hiddenItems are per-tray.
        #
        # The item lists are NOT set here: Plasma reads them from the PRIVATE
        # systemtray containment rather than the applet, so plasma-manager
        # writing them to the applet has no effect. plasma.nix's fixSystemTray
        # activation writes the real containments; these two entries only
        # declare that two trays exist and in what order.
        { name = "org.kde.plasma.systemtray"; }
        { name = "org.kde.plasma.systemtray"; }

        # No clock here — it lives on the top panel only. Two clocks on one
        # screen is just two clocks.
      ];
    }
  ];
}
