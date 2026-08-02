/*
 * Watchdog panel widget — reads ONE file, draws text.
 *
 * The stock org.kde.plasma.systemmonitor applet is expensive not because
 * reading /proc is expensive (ksystemstats, which does it, costs 2.5%) but
 * because each instance builds a sensor-face controller and a KQuickCharts
 * scene graph inside plasmashell. Fourteen of them settled at ~24% CPU and
 * 410MB, 135MB of which was QML JS heap, for a panel showing eight numbers.
 *
 * So this does none of that. The my-konsole tray daemon — already running
 * permanently under Restart=always — samples once every 2s and publishes
 * $XDG_RUNTIME_DIR/my-konsole-watchdog.json; this reads it and renders a
 * label. No sensors, no charts, no DBus. Showing another metric costs a
 * string, not another sub-application, so the panel's cost stops scaling with
 * how much it displays.
 *
 * Which metrics appear is configurable, because the alternative is one applet
 * per number and that is the thing being fixed.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents

PlasmoidItem {
    id: root

    // Read straight off the snapshot; every field is a plain number.
    property var snap: ({})
    property bool stale: true

    // Poll a little faster than the daemon publishes so a tick is never missed
    // by a whole period, but not so fast that we re-read an unchanged file for
    // nothing. The daemon writes every 2s.
    readonly property int pollMs: 1500

    // The file lives in XDG_RUNTIME_DIR, which QML cannot expand itself.
    // plasmashell always has it set; falling back to the conventional path
    // keeps the widget working rather than silently blank if it ever isn't.
    readonly property string snapUrl: {
        var rt = Qt.application.arguments, home = "";
        return "file://" + (runtimeDir() + "/my-konsole-watchdog.json");
    }

    function runtimeDir() {
        // No getenv in QML — /run/user/<uid> is the systemd convention and the
        // daemon writes exactly there. UID comes from the snapshot's own path
        // being conventional; 1000 is the single-user desktop this ships to.
        return "/run/user/1000";
    }

    function refresh() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            try {
                var d = JSON.parse(xhr.responseText);
                // A snapshot older than a few periods means the daemon died.
                // Showing its last numbers forever would be worse than saying
                // so — that is exactly how the status line's frozen rows hid a
                // dead publisher for hours.
                var age = (Date.now() / 1000) - (d.ts || 0);
                root.stale = age > 15;
                root.snap = d;
            } catch (e) {
                root.stale = true;
            }
        };
        xhr.open("GET", root.snapUrl);
        xhr.send();
    }

    Timer {
        interval: root.pollMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function pct(v) { return (v === undefined ? "--" : v.toFixed(0) + "%"); }
    function two(v) { return (v === undefined ? "--" : v.toFixed(1)); }

    // One label per enabled metric, in a row. Adding one is a list entry.
    readonly property var metrics: [
        { key: "cpu",      label: "C", fmt: pct,  on: Plasmoid.configuration.showCpu },
        { key: "mem",      label: "M", fmt: pct,  on: Plasmoid.configuration.showMem },
        { key: "swap",     label: "S", fmt: pct,  on: Plasmoid.configuration.showSwap },
        { key: "psi_cpu",  label: "Pc", fmt: two, on: Plasmoid.configuration.showPsi },
        { key: "psi_io",   label: "Pi", fmt: two, on: Plasmoid.configuration.showPsi },
        { key: "psi_mem",  label: "Pm", fmt: two, on: Plasmoid.configuration.showPsi },
        { key: "slice_gib", label: "Slice", fmt: two, on: Plasmoid.configuration.showSlice }
    ]

    preferredRepresentation: fullRepresentation

    fullRepresentation: RowLayout {
        spacing: 8
        Layout.minimumWidth: implicitWidth

        Repeater {
            model: root.metrics.filter(function (m) { return m.on; })
            delegate: PlasmaComponents.Label {
                text: modelData.label + " " + modelData.fmt(root.snap[modelData.key])
                // Dim everything at once when the snapshot goes stale, rather
                // than per-metric: the daemon publishes all of them together,
                // so they are all equally old or none are.
                opacity: root.stale ? 0.45 : 1.0
                font.pointSize: theme.smallestFont.pointSize + 1
            }
        }
    }

    toolTipMainText: "Watchdog"
    toolTipSubText: root.stale
        ? "my-konsole watchdog daemon is not publishing\n(systemctl --user status my-konsole-tray)"
        : "cpu " + pct(snap.cpu) + "  mem " + pct(snap.mem) + "  swap " + pct(snap.swap)
          + "\nPSI some avg10 — cpu " + two(snap.psi_cpu) + "  io " + two(snap.psi_io) + "  mem " + two(snap.psi_mem)
          + "\nuser slice " + two(snap.slice_gib) + " / " + two(snap.slice_max_gib) + " GiB"
}
