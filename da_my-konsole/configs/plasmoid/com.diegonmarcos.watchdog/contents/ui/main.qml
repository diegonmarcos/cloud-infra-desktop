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

    // freeze-guard's own PSI-voter state, published by the SYSTEM-level
    // watchdog (root-watchdog, configuration_system-protection.nix) — a
    // separate publisher from the my-konsole tray daemon above, hence its own
    // snap/stale pair and its own poll Timer below. The file will not exist
    // until a system rebuild lands the publish() change, so every access
    // below MUST be defensive (missing file / parse failure / missing
    // properties → neutral empty state, never a QML error that blanks the
    // whole applet — that regression was just fixed once already).
    property var guardSnap: ({})
    property bool guardStale: true

    readonly property int pollMs: 1500   // daemon publishes every 2s
    readonly property string runtimeDir: "/run/user/" + Plasmoid.configuration.uid
    readonly property string snapUrl: "file://" + runtimeDir + "/my-konsole-watchdog.json"
    readonly property string killPath: runtimeDir + "/my-konsole-watchdog.kill"
    readonly property string guardUrl: "file:///run/freeze-guard.json"

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

    // Same shape as refresh() above, against freeze-guard's own snapshot.
    // On ANY failure (file absent, bad JSON, mid-write partial read) fall
    // back to an empty object + stale=true rather than throwing — the guard
    // cluster below already treats {} as "nothing to show".
    function refreshGuard() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            try {
                var d = JSON.parse(xhr.responseText);
                root.guardStale = ((Date.now() / 1000) - (d.ts || 0)) > 15;
                root.guardSnap = d || {};
            } catch (e) {
                root.guardStale = true;
                root.guardSnap = {};
            }
        };
        xhr.open("GET", root.guardUrl);
        xhr.send();
    }

    Timer {
        interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refreshGuard()
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

    // ── freeze-guard voter helpers — every one defensive: guardSnap is {}
    // until the first successful poll, and stays {} forever on a machine
    // that hasn't rebuilt with the publish() change yet. Every accessor here
    // must degrade to "empty"/"neutral", never touch a property of undefined.
    function guardVoters() {
        return (root.guardSnap && root.guardSnap.voters) ? root.guardSnap.voters : [];
    }
    // value/threshold as a percent (100 = exactly at the kill line), fed into
    // the existing Bar component the same way the PSI bars use a 0-100 value.
    function guardRatio(v) {
        if (!v || !v.threshold) return 0;
        return (v.value || 0) / v.threshold * 100;
    }
    function guardColor(v) {
        if (!v) return Kirigami.Theme.disabledTextColor;
        if (v.armed) return Kirigami.Theme.negativeTextColor;
        return root.heat(root.guardRatio(v));
    }
    // Two-letter tags so 7 bars fit a 30px-tall panel row; falls back to the
    // full id (still short) for any voter this map hasn't been taught yet —
    // additive-safe if the JSON ever grows a voter.
    readonly property var guardShortLabels: ({
        "mem_psi_full": "Mp", "io_psi_full": "Ip", "cpu_psi_some": "Cp",
        "desktop_io_psi_full": "dI", "desktop_mem_psi_full": "dM",
        "mem_high_thrash": "Th", "write_storm": "Ws"
    })
    function shortGuardLabel(v) {
        if (!v) return "?";
        return root.guardShortLabels[v.id] || (v.id ? v.id.substring(0, 2) : "?");
    }
    // One "label  value/threshold  (Ns/Ns)" line per voter, for the tooltip.
    function guardTooltipLines() {
        var voters = root.guardVoters();
        if (!voters.length) return root.guardStale ? "freeze-guard: not publishing" : "";
        var lines = [];
        for (var i = 0; i < voters.length; i++) {
            var v = voters[i];
            if (!v) continue;
            var label = v.label || v.id || "?";
            var value = (v.value !== undefined && v.value !== null) ? Number(v.value).toFixed(1) : "--";
            var thr = (v.threshold !== undefined && v.threshold !== null) ? v.threshold : "--";
            var sus = (v.sustain !== undefined && v.sustain !== null) ? v.sustain : 0;
            var susNeed = (v.sustain_need !== undefined && v.sustain_need !== null) ? v.sustain_need : 0;
            lines.push(label + "  " + value + "/" + thr + "  (" + sus + "s/" + susNeed + "s)" + (v.armed ? "  ARMED" : ""));
        }
        return lines.join("\n");
    }

    // Short mount label for the disk bars — "/" stays "/", everything else
    // is the last path segment ("home", "boot" for "/boot").
    function shortMount(m) {
        if (!m) return "?";
        if (m === "/") return "/";
        var parts = m.split("/");
        return parts[parts.length - 1] || m;
    }

    // mem_detail ({total,used,buffers,cached,free} GiB) is what the sampler
    // is growing to emit; today's daemon only has the overall `mem` percent.
    // Fall back to a two-segment used/free ring so the pie still means
    // something instead of throwing on the missing field.
    function memLayers() {
        var m = root.snap.mem_detail;
        if (m && m.total) return [m.used || 0, m.buffers || 0, m.cached || 0, m.free || 0];
        var used = root.snap.mem || 0;
        return [used, 100 - used];
    }
    function memLayerColors() {
        var m = root.snap.mem_detail;
        if (m && m.total)
            return [Kirigami.Theme.highlightColor, Kirigami.Theme.neutralTextColor,
                    Kirigami.Theme.positiveTextColor, Kirigami.Theme.disabledTextColor];
        return [Kirigami.Theme.highlightColor, Kirigami.Theme.disabledTextColor];
    }
    // Centre number: reclaimable memory as a percent of total (free + buffers
    // + cached) / total — falls back to 100 - mem% when mem_detail is absent.
    function memCentreText() {
        var m = root.snap.mem_detail;
        if (m && m.total)
            return Math.round(((m.free || 0) + (m.buffers || 0) + (m.cached || 0)) / m.total * 100) + "%";
        return root.snap.mem !== undefined ? Math.round(100 - root.snap.mem) + "%" : "--";
    }

    // vram is JSON `null` on machines with no discrete GPU sysfs node — that
    // is normal here, not an error, so callers must treat undefined as "—".
    function vramPct() {
        var v = root.snap.vram;
        if (!v || !v.total) return undefined;
        return (v.used / v.total) * 100;
    }

    // slice_pct is the sampler's future field; derive it from the GiB pair
    // that is already published today so the pie isn't blank in the meantime.
    function slicePct() {
        if (root.snap.slice_pct !== undefined) return root.snap.slice_pct;
        if (root.snap.slice_max_gib) return (root.snap.slice_gib / root.snap.slice_max_gib) * 100;
        return undefined;
    }

    function pct0(v) { return v === undefined ? "--" : Math.round(v) + "%"; }

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

    // ── layered pie: several segments in one ring, e.g. mem used/buffers/
    // cached/free. Chart.IndexAllValues treats a single ArraySource's array
    // as one segment per entry instead of one source per segment — confirmed
    // against Chart/ArraySource/PieChart in kquickcharts' QuickCharts.qmltypes.
    component MultiPie : Item {
        id: mpie
        property string label: ""
        property var values: []
        property var colors: []
        implicitWidth: 26
        implicitHeight: 26

        Charts.PieChart {
            anchors.fill: parent
            range { automatic: true }
            indexingMode: Charts.Chart.IndexAllValues
            valueSources: [ Charts.ArraySource { array: mpie.values } ]
            colorSource: Charts.ArraySource { array: mpie.colors }
            backgroundColor: Kirigami.Theme.backgroundColor
            thickness: 5
            filled: false
        }
        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: mpie.label
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
            // 38x8 was sized for one row of six. Stacked 3x2 in a 30px panel
            // the height has to come down with it, and the extra column of
            // width is what stops the whole cluster overflowing.
            Layout.preferredWidth: 30
            Layout.preferredHeight: 6
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

            // LEFT cluster: disk bars, mem/swap/vram/cpu as pies with the
            // headline number centred in the ring.
            Loader {
                active: Plasmoid.configuration.mode === "left"
                visible: active
                sourceComponent: RowLayout {
                    spacing: 6

                    // 1. disk-usage — one thin horizontal bar per mount.
                    // `disks` is another field the sampler hasn't shipped
                    // yet; an empty model just renders no bars.
                    ColumnLayout {
                        spacing: 1
                        Repeater {
                            model: root.snap.disks || []
                            delegate: Bar {
                                label: root.shortMount(modelData.mount)
                                value: modelData.pct || 0
                                fill: root.heat(modelData.pct)
                            }
                        }
                    }

                    // 2. mem-usage — layered ring (used/buffers/cached/free),
                    // centre = reclaimable percent.
                    MultiPie {
                        label: root.memCentreText()
                        values: root.memLayers()
                        colors: root.memLayerColors()
                    }

                    // 3. swap-usage
                    Pie {
                        label: root.pct0(root.snap.swap)
                        value: root.snap.swap || 0
                        fill: root.heat(root.snap.swap)
                    }

                    // 4. vram-usage — vram is null on this machine (no
                    // discrete GPU sysfs node); show a grey ring and "--"
                    // rather than hiding it or erroring.
                    Pie {
                        label: root.vramPct() !== undefined ? root.pct0(root.vramPct()) : "--"
                        value: root.vramPct() || 0
                        fill: root.vramPct() !== undefined ? root.heat(root.vramPct()) : Kirigami.Theme.disabledTextColor
                    }

                    // 5. cpu-usage
                    Pie {
                        label: root.pct0(root.snap.cpu)
                        value: root.snap.cpu || 0
                        fill: root.heat(root.snap.cpu)
                    }
                }
            }

            // RIGHT cluster: user-slice pie, three `some` PSI bars, three
            // `full` PSI bars.
            Loader {
                active: Plasmoid.configuration.mode === "right"
                visible: active
                sourceComponent: RowLayout {
                    spacing: 6

                    // 1. slices-usage — percent of the user cgroup slice's
                    // memory.max in use. slice_pct is another field the
                    // sampler hasn't shipped yet; derive it from slice_gib /
                    // slice_max_gib, which today's daemon already publishes.
                    Pie {
                        label: root.pct0(root.slicePct())
                        value: root.slicePct() || 0
                        fill: root.heat(root.slicePct())
                    }

                    // 2 & 3. Six bars in ONE row ran ~400px and overflowed the
                    // top panel. They are 3x2 now: `some` on top, `full`
                    // beneath, cpu/io/memory in the same column both times, so
                    // a column reads as one resource and the pair reads as
                    // "some of it stalled" over "all of it stalled". Halves
                    // the width and spends panel height that was already there.
                    GridLayout {
                        columns: 3
                        rowSpacing: 1
                        columnSpacing: 5
                        Bar { label: "Sc"; value: root.psi("cpu","some10")    || 0; fill: root.heat(root.psi("cpu","some10")) }
                        Bar { label: "Si"; value: root.psi("io","some10")     || 0; fill: root.heat(root.psi("io","some10")) }
                        Bar { label: "Sm"; value: root.psi("memory","some10") || 0; fill: root.heat(root.psi("memory","some10")) }
                        Bar { label: "Fc"; value: root.psi("cpu","full10")    || 0; fill: root.heat(root.psi("cpu","full10")) }
                        Bar { label: "Fi"; value: root.psi("io","full10")     || 0; fill: root.heat(root.psi("io","full10")) }
                        Bar { label: "Fm"; value: root.psi("memory","full10") || 0; fill: root.heat(root.psi("memory","full10")) }
                    }
                }
            }

            // GUARD cluster: freeze-guard's own voter state (mem/io/cpu PSI,
            // desktop-starvation, memory.high thrash, write-storm — see
            // configuration_system-protection.nix). Defensive throughout:
            // /run/freeze-guard.json won't exist until a rebuild lands this,
            // and guardVoters()/guardRatio()/guardColor() all degrade to an
            // empty/neutral render rather than throwing. 4 columns so 7
            // voters fold into 2 rows instead of overflowing one, same
            // reasoning as the existing 3x2 PSI grid above.
            Loader {
                active: Plasmoid.configuration.mode === "guard"
                visible: active
                sourceComponent: GridLayout {
                    columns: 4
                    rowSpacing: 1
                    columnSpacing: 5
                    Repeater {
                        model: root.guardVoters()
                        delegate: Bar {
                            label: root.shortGuardLabel(modelData)
                            value: root.guardRatio(modelData)
                            fill: root.guardColor(modelData)
                        }
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
          + (root.guardTooltipLines() ? "\n\nfreeze-guard voters:\n" + root.guardTooltipLines() : "")
}
