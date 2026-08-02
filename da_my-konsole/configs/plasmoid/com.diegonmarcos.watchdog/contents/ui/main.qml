/*
 * Watchdog panel widget — reads ONE file, draws everything.
 *
 * The stock org.kde.plasma.systemmonitor applet is expensive, but NOT because
 * of the charts and not because reading /proc is slow — ksystemstats, which
 * actually reads it, costs 2.5%. It is that each applet instance carries a
 * sensor-face controller and its own ksystemstats subscription. Fourteen of
 * them settled at ~24% CPU and 410MB, 135MB of it QML JS heap, for eight
 * numbers.
 *
 * So the charts stay and the plumbing goes. org.kde.quickcharts is the same
 * library KSysGuard's own piechart face draws with, used here directly against
 * values from $XDG_RUNTIME_DIR/my-konsole-watchdog.json — one file the
 * my-konsole tray daemon publishes every 2s. No sensor faces, no per-applet
 * subscriptions, one sampler for the whole machine.
 *
 * `mode` picks which cluster an instance renders, so one widget serves the
 * whole panel and another metric is a config change rather than another applet.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.quickcharts as Charts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    property var snap: ({})
    property bool stale: true

    readonly property int pollMs: 1500   // daemon publishes every 2s
    readonly property string runtimeDir: "/run/user/" + Plasmoid.configuration.uid
    readonly property string snapUrl: "file://" + runtimeDir + "/my-konsole-watchdog.json"
    readonly property string killPath: runtimeDir + "/my-konsole-watchdog.kill"

    function refresh() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            try {
                var d = JSON.parse(xhr.responseText);
                // Older than a few periods means the daemon died. Showing its
                // last numbers forever is how a dead publisher hides — exactly
                // what froze the Claude status line for hours.
                root.stale = ((Date.now() / 1000) - (d.ts || 0)) > 15;
                root.snap = d;
            } catch (e) {
                root.stale = true;
            }
        };
        xhr.open("GET", root.snapUrl);
        xhr.send();
    }

    Timer {
        interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function pct(v)  { return (v === undefined ? "--" : v.toFixed(0) + "%"); }
    function two(v)  { return (v === undefined ? "--" : v.toFixed(1)); }
    function mbs(v)  { return (v === undefined ? "--" : v.toFixed(1) + "M/s"); }
    function psi(k, f) { return (snap.psi && snap.psi[k]) ? snap.psi[k][f] : undefined; }

    // Battery text for tooltip/header. `battery` is JSON `null` on a desktop
    // (no BAT* in sysfs), `{present:false}` if the kernel briefly reports no
    // cell, or the full reading otherwise. minutes_left is JSON `null`
    // whenever the daemon couldn't safely compute a rate (charging, or
    // power_now zero/absent) — never trust it to always be a number.
    function batteryText() {
        var b = root.snap.battery;
        if (!b || !b.present) return "";
        var t = "batt " + b.pct.toFixed(0) + "% " + b.status;
        if (b.minutes_left !== null && b.minutes_left !== undefined) {
            var h = Math.floor(b.minutes_left / 60);
            var m = Math.round(b.minutes_left % 60);
            t += " (" + h + "h" + m + "m left)";
        }
        return t;
    }

    // Pressure earns colour: it predicts a stall, and the reason this panel
    // exists is a machine that froze with nothing on screen saying so.
    function heat(v) {
        if (v === undefined) return Kirigami.Theme.disabledTextColor;
        if (v >= 40) return Kirigami.Theme.negativeTextColor;
        if (v >= 15) return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.positiveTextColor;
    }

    // ── pie, the same element KSysGuard's piechart face uses ─────────────────
    component Pie : Item {
        id: pie
        property string label: ""
        property real value: 0
        property color fill: Kirigami.Theme.highlightColor
        implicitWidth: 26
        implicitHeight: 26

        Charts.PieChart {
            anchors.fill: parent
            range { from: 0; to: 100; automatic: false }
            valueSources: Charts.SingleValueSource { value: pie.value }
            colorSource: Charts.SingleValueSource { value: pie.fill }
            backgroundColor: Kirigami.Theme.backgroundColor
            thickness: 5
            filled: false
        }
        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: pie.label
            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
            opacity: 0.9
        }
    }

    // ── horizontal bar, for the PSI row ──────────────────────────────────────
    component Bar : RowLayout {
        id: bar
        property string label: ""
        property real value: 0
        property color fill: Kirigami.Theme.highlightColor
        spacing: 3
        PlasmaComponents.Label {
            text: bar.label
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.75
        }
        Rectangle {
            Layout.preferredWidth: 38
            Layout.preferredHeight: 8
            radius: 2
            color: Kirigami.Theme.backgroundColor
            border { color: Kirigami.Theme.disabledTextColor; width: 1 }
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                width: Math.max(0, Math.min(1, bar.value / 100)) * (parent.width - 2)
                radius: 1
                color: bar.fill
                // Deliberately not animated: a 2s sample eased over 2s is a
                // repaint every frame, which is the cost being removed.
            }
        }
    }

    // Every signal the daemon accepts. A process table that can only destroy is
    // a blunt instrument — STOP freezes a runaway without losing its state,
    // which on this box is usually the right first move, and HUP reloads a
    // daemon rather than ending it.
    readonly property var signalList: [
        { sig: "TERM", label: "Term — ask it to exit" },
        { sig: "INT",  label: "Int — as if Ctrl-C" },
        { sig: "HUP",  label: "HUP — reload / hangup" },
        { sig: "QUIT", label: "Quit — exit + core dump" },
        { sig: "STOP", label: "Stop — freeze, keep state" },
        { sig: "CONT", label: "Cont — resume a stopped one" },
        { sig: "USR1", label: "USR1 — application-defined" },
        { sig: "KILL", label: "Kill — unignorable, no cleanup" }
    ]

    // QML cannot signal a process. Handing a panel widget an exec path is worse
    // than handing the daemon a mailbox: the daemon runs as this user, so it
    // can only ever signal what the user already could.
    //
    // Writing to that mailbox is its own problem: QML's XMLHttpRequest against
    // a file:// URL only ever supports GET in Qt's implementation — there is
    // no writable file scheme handler, so a PUT here silently does nothing
    // and every signal request would vanish. The executable data engine is
    // the supported way a plasmoid runs a shell command; used here only to
    // append a line, never to run anything built from unsanitised input.
    Plasma5Support.DataSource {
        id: killWriter
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName) => disconnectSource(sourceName)
    }

    function sendSignal(pid, sig) {
        var cmd = "printf '%s %s\\n' '" + pid + "' '" + sig + "' >> '" + root.killPath + "'";
        killWriter.connectSource(cmd);
    }

    preferredRepresentation: compactRepresentation

    compactRepresentation: MouseArea {
        implicitWidth: row.implicitWidth
        implicitHeight: Math.max(row.implicitHeight, 26)
        onClicked: root.expanded = !root.expanded

        RowLayout {
            id: row
            anchors.fill: parent
            spacing: 9
            opacity: root.stale ? 0.45 : 1.0

            // LEFT cluster: memory, swap, cpu as pies; per-core as thin bars.
            Loader {
                active: Plasmoid.configuration.mode === "left"
                visible: active
                sourceComponent: RowLayout {
                    spacing: 6
                    Pie { label: "M"; value: root.snap.mem  || 0; fill: Kirigami.Theme.highlightColor }
                    Pie { label: "S"; value: root.snap.swap || 0; fill: Kirigami.Theme.neutralTextColor }
                    Pie { label: "C"; value: root.snap.cpu  || 0; fill: root.heat(root.snap.cpu) }
                    RowLayout {
                        spacing: 2
                        Repeater {
                            model: root.snap.cores || []
                            delegate: Rectangle {
                                width: 4; height: 16; radius: 1
                                color: Kirigami.Theme.backgroundColor
                                border { color: Kirigami.Theme.disabledTextColor; width: 1 }
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 1 }
                                    height: Math.max(0, Math.min(1, modelData / 100)) * (parent.height - 2)
                                    color: root.heat(modelData)
                                    radius: 1
                                }
                            }
                        }
                    }
                }
            }

            // RIGHT cluster: disk r/w, three `some` PSI bars, three `full` PSI
            // bars, and the 1-minute cpu trend.
            Loader {
                active: Plasmoid.configuration.mode === "right"
                visible: active
                sourceComponent: RowLayout {
                    spacing: 6
                    PlasmaComponents.Label {
                        text: "R " + root.mbs(root.snap.disk_r) + "  W " + root.mbs(root.snap.disk_w)
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    Bar { label: "Sc"; value: root.psi("cpu","some10")    || 0; fill: root.heat(root.psi("cpu","some10")) }
                    Bar { label: "Si"; value: root.psi("io","some10")     || 0; fill: root.heat(root.psi("io","some10")) }
                    Bar { label: "Sm"; value: root.psi("memory","some10") || 0; fill: root.heat(root.psi("memory","some10")) }
                    Bar { label: "Fc"; value: root.psi("cpu","full10")    || 0; fill: root.heat(root.psi("cpu","full10")) }
                    Bar { label: "Fi"; value: root.psi("io","full10")     || 0; fill: root.heat(root.psi("io","full10")) }
                    Bar { label: "Fm"; value: root.psi("memory","full10") || 0; fill: root.heat(root.psi("memory","full10")) }
                    // A 60s average printed rather than barred: a bar of a
                    // trend reads like a live value and isn't one.
                    PlasmaComponents.Label {
                        text: "1m " + root.two(root.psi("cpu","some60"))
                        color: root.heat(root.psi("cpu","some60"))
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
        }
    }

    // ── expanded: process table, every signal available ──────────────────────
    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 26
        Layout.minimumHeight: Kirigami.Units.gridUnit * 22

        header: PlasmaExtras.PlasmoidHeading {
            contentItem: PlasmaComponents.Label {
                text: root.stale
                    ? "watchdog daemon is not publishing"
                    : "slice " + root.two(root.snap.slice_gib) + " / " + root.two(root.snap.slice_max_gib) + " GiB"
                      + "   ·   load " + root.two(root.snap.load1) + " " + root.two(root.snap.load5) + " " + root.two(root.snap.load15)
                      + "   ·   net ↓" + root.mbs(root.snap.net_rx) + " ↑" + root.mbs(root.snap.net_tx)
                      + (root.batteryText() ? "   ·   " + root.batteryText() : "")
                elide: Text.ElideRight
            }
        }

        ListView {
            id: procList
            model: root.snap.procs || []
            clip: true
            spacing: 2
            delegate: RowLayout {
                id: procRow
                // The inner Repeater below (over signalList) has its own
                // modelData/index that shadow this delegate's — reading
                // procList.model[index] inside onTriggered used the SIGNAL
                // list's index against the PROCESS list, sending a signal to
                // whatever pid happened to sit at that row instead of the one
                // the menu was opened on. Capture the pid up front instead.
                property int procPid: modelData.pid
                width: procList.width
                spacing: 6
                PlasmaComponents.Label { text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight }
                PlasmaComponents.Label { text: modelData.rss + "M"; opacity: 0.85 }
                PlasmaComponents.Label { text: modelData.pid; opacity: 0.5 }
                PlasmaComponents.Button {
                    text: "Signal"
                    icon.name: "process-stop"
                    onClicked: sigMenu.open()
                    PlasmaComponents.Menu {
                        id: sigMenu
                        Repeater {
                            model: root.signalList
                            delegate: PlasmaComponents.MenuItem {
                                text: modelData.label
                                onTriggered: root.sendSignal(procRow.procPid, modelData.sig)
                            }
                        }
                    }
                }
            }
        }
    }

    toolTipMainText: "Watchdog"
    toolTipSubText: root.stale
        ? "my-konsole watchdog daemon is not publishing\n(systemctl --user status my-konsole-tray)"
        : "cpu " + pct(snap.cpu) + "   mem " + pct(snap.mem) + "   swap " + pct(snap.swap)
          + "\ndisk " + pct(snap.disk) + "   r " + mbs(snap.disk_r) + "   w " + mbs(snap.disk_w)
          + "\nnet ↓" + mbs(snap.net_rx) + "  ↑" + mbs(snap.net_tx)
          + "\nload " + two(snap.load1) + "  " + two(snap.load5) + "  " + two(snap.load15)
          + "\nPSI some avg10  cpu " + two(psi("cpu","some10")) + "  io " + two(psi("io","some10")) + "  mem " + two(psi("memory","some10"))
          + "\nPSI full avg10  cpu " + two(psi("cpu","full10")) + "  io " + two(psi("io","full10")) + "  mem " + two(psi("memory","full10"))
          + "\nuser slice " + two(snap.slice_gib) + " / " + two(snap.slice_max_gib) + " GiB"
          + (batteryText() ? "\n" + batteryText() : "")
}
