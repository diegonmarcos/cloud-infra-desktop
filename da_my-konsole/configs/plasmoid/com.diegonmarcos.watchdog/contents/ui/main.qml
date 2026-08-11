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
 * The cluster COMPOSITION (title + which items, in which order) is data —
 * contents/data/clusters.json — read once at startup via XHR against
 * Qt.resolvedUrl(); main.qml supplies the kind->component mapping and the
 * metric->{value,label,fill} lookups the JSON's item entries name. Growing a
 * mode means editing that JSON, not adding another hardcoded Loader block.
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

    // ── clusters.json: which items each mode's cluster draws, and its title.
    // Read once, synchronously, at startup — it is a small static file
    // shipped inside the plasmoid, not a value that changes at runtime like
    // snap/guardSnap above, so there is no polling Timer for it. Sync XHR
    // against a local file:// URL is supported by QML's XMLHttpRequest and
    // keeps clusterDefs populated before the first paint instead of racing an
    // async load against the compact representation's first layout pass.
    // Qt.resolvedUrl() is used (rather than the bare relative string
    // "data/clusters.json") because that string would resolve relative to
    // this file's own directory (contents/ui/), not contents/ — verified by
    // reading Qt.resolvedUrl's own resolution rules; "../data/clusters.json"
    // from contents/ui/main.qml correctly lands on contents/data/clusters.json.
    readonly property string clustersUrl: Qt.resolvedUrl("../data/clusters.json")
    property var clusterDefs: ({})

    function loadClusters() {
        var xhr = new XMLHttpRequest();
        try {
            xhr.open("GET", root.clustersUrl, false); // sync: tiny static file, once
            xhr.send();
            root.clusterDefs = JSON.parse(xhr.responseText);
        } catch (e) {
            // Missing/unparsable clusters.json must not blank the whole
            // applet — same defensive stance as refresh()/refreshGuard().
            root.clusterDefs = {};
        }
    }

    // The cluster this instance renders, keyed by Plasmoid.configuration.mode.
    // Falls back to an empty title/items pair for a mode string clusters.json
    // doesn't (yet) know about, rather than throwing.
    readonly property var currentCluster: root.clusterDefs[Plasmoid.configuration.mode] || { title: "", items: [] }

    Component.onCompleted: root.loadClusters()

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
    // Lives in the `cpu` cluster (see clusters.json) rather than its own mode:
    // it is CPU's GPU sibling, not a resource big enough to earn a panel slot
    // of its own on a machine that mostly doesn't have a discrete GPU anyway.
    function vramPct() {
        var v = root.snap.vram;
        if (!v || !v.total) return undefined;
        return (v.used / v.total) * 100;
    }

    // slice_pct is published directly today; the GiB-pair fallback covers an
    // older daemon build that hasn't been rebuilt yet.
    function slicePct() {
        if (root.snap.slice_pct !== undefined) return root.snap.slice_pct;
        if (root.snap.slice_max_gib) return (root.snap.slice_gib / root.snap.slice_max_gib) * 100;
        return undefined;
    }

    function pct0(v) { return v === undefined ? "--" : Math.round(v) + "%"; }

    // Bytes/sec -> human string for the proctable's read/write columns.
    // Matches mbs()'s one-decimal style but scales down to K/s since a lot
    // of processes sit well under 1 MB/s and "0.0M/s" for everything below
    // that would make the column useless for sorting-by-eye.
    function bps(v) {
        if (v === undefined || v === null) return "--";
        if (v >= 1048576) return (v / 1048576).toFixed(1) + "M/s";
        if (v >= 1024) return (v / 1024).toFixed(1) + "K/s";
        return Math.round(v) + "B/s";
    }

    // Bytes (absolute, not per-second) -> human string, for the RSS column.
    function bytesFmt(v) {
        if (v === undefined || v === null) return "--";
        if (v >= 1073741824) return (v / 1073741824).toFixed(1) + "G";
        if (v >= 1048576) return (v / 1048576).toFixed(0) + "M";
        if (v >= 1024) return (v / 1024).toFixed(0) + "K";
        return Math.round(v) + "B";
    }

    // ── proctable mode: sortable multi-column process table ──────────────────
    // Column set matches the `proc_table` JSON keys 1:1 so sorting is a
    // straight compare on modelData[key], never a re-derivation.
    readonly property var ptColumns: [
        { key: "name",              label: "Name",  width: 130 },
        { key: "user",              label: "User",  width: 70 },
        { key: "pid",               label: "PID",   width: 55 },
        { key: "cpu_pct",           label: "CPU%",  width: 55 },
        { key: "mem_pct",           label: "Mem%",  width: 55 },
        { key: "mem_rss_bytes",     label: "RSS",   width: 65 },
        { key: "read_bytes_per_s",  label: "Read",  width: 65 },
        { key: "write_bytes_per_s", label: "Write", width: 65 },
        { key: "runq_wait_pct",     label: "RunQ%", width: 60 }
    ]
    // Same metrics as ptColumns, minus name/user/pid (not meaningfully
    // "sortable" as a ranking) — friendly names for the explicit sort
    // selector, since the header click affordance turned out to be
    // undiscoverable on its own. runq_wait_pct is per-process PSI-CPU
    // (scheduler run-queue wait): the short "RunQ%" column header stays,
    // but the selector spells out what it means.
    readonly property var ptSortableMetrics: [
        { key: "cpu_pct",           label: "CPU %" },
        { key: "mem_pct",           label: "Mem %" },
        { key: "mem_rss_bytes",     label: "Mem RSS" },
        { key: "runq_wait_pct",     label: "PSI-CPU (runq wait)" },
        { key: "read_bytes_per_s",  label: "Read rate" },
        { key: "write_bytes_per_s", label: "Write rate" }
    ]
    property string ptSortKey: "cpu_pct"
    property bool ptSortAsc: false

    // Header click: same key toggles direction, a different key selects it
    // descending (the useful default for every one of these — "biggest
    // consumer first").
    function ptSort(key) {
        if (root.ptSortKey === key) root.ptSortAsc = !root.ptSortAsc;
        else { root.ptSortKey = key; root.ptSortAsc = false; }
    }
    // Explicit selector (ComboBox): always sets the key descending, even if
    // it's already the current key — picking from a list is a statement of
    // intent, not a toggle request.
    function ptSelectSort(key) {
        root.ptSortKey = key;
        root.ptSortAsc = false;
    }

    // Sorted copy of proc_table — never mutates root.snap.proc_table itself,
    // since that array is replaced wholesale by refresh() every poll and a
    // sort-in-place would race a JSON.parse landing mid-sort.
    function ptSorted() {
        var arr = (root.snap.proc_table || []).slice();
        var key = root.ptSortKey, asc = root.ptSortAsc;
        arr.sort(function (a, b) {
            var av = a[key], bv = b[key];
            if (typeof av === "string") {
                av = (av || "").toLowerCase();
                bv = (bv || "").toLowerCase();
            } else {
                av = av || 0;
                bv = bv || 0;
            }
            if (av < bv) return asc ? -1 : 1;
            if (av > bv) return asc ? 1 : -1;
            return 0;
        });
        return arr;
    }

    // Formatted cell text for one (row, column) pair.
    function ptCellText(row, key) {
        switch (key) {
            case "cpu_pct":
            case "runq_wait_pct": return Number(row[key] || 0).toFixed(1) + "%";
            case "mem_pct": return Number(row[key] || 0).toFixed(1) + "%";
            case "mem_rss_bytes": return root.bytesFmt(row[key]);
            case "read_bytes_per_s":
            case "write_bytes_per_s": return root.bps(row[key]);
            default: return String(row[key] !== undefined ? row[key] : "--");
        }
    }

    // ── compact-representation sizing — the actual bug being fixed. Every
    // pie/bar/font size below derives from contentH instead of a fixed pixel
    // number, so the widget fits whatever thickness the panel gives it
    // (44px top / 60px bottom here, see top-panel.json/bottom-panel.json)
    // instead of overflowing/overlapping at a size nobody chose.
    //
    // availH is the height the panel containment actually granted the
    // COMPACT REPRESENTATION instance — not root.height. root is the
    // PlasmoidItem, and in a panel the PlasmoidItem's own height is not
    // reliably the panel thickness; the item the containment layout actually
    // sizes to the panel is compactRepresentation (compactRoot below). A
    // Binding down in compactRepresentation pushes compactRoot.height into
    // this property, one-way, so nothing here reads back from a size this
    // same property influences — contentH must never feed something that
    // feeds availH, or it becomes the exact feedback loop that was here
    // before (implicitHeight computed from contentH, contentH computed from
    // the height implicitHeight was supposed to inform).
    property int availH: 0
    readonly property real titleH: Math.max(9, Math.round(Kirigami.Theme.smallFont.pixelSize * 1.2))
    readonly property real clusterSpacing: 2
    // The Math.max floor is load-bearing, not decorative, on TWO counts:
    // first frame availH is still 0 (the Binding below hasn't fired yet), so
    // without a floor this would go negative before any panel geometry
    // exists at all. Second, KDE bug 489307 is the same failure mode at a
    // nonzero-but-small panel thickness — a chart-style widget's rendered
    // size collapsing to zero, so the widget occupies no visible space
    // rather than merely looking small. bottom-panel.json documents that
    // incident; this floor exists so this widget cannot repeat it no matter
    // how thin a panel someone picks, or how early this binding evaluates.
    readonly property real contentH: Math.max(16, root.availH - root.titleH - root.clusterSpacing)
    readonly property real fontPt: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize, root.contentH / 4))

    // ── pie, the same element KSysGuard's piechart face uses ─────────────────
    component Pie : Item {
        id: pie
        property string label: ""
        property real value: 0
        property color fill: Kirigami.Theme.highlightColor
        property real size: 26   // floor/default; callers bind this to root.contentH
        implicitWidth: Math.max(16, size)
        implicitHeight: Math.max(16, size)

        Charts.PieChart {
            anchors.fill: parent
            range { from: 0; to: 100; automatic: false }
            valueSources: Charts.SingleValueSource { value: pie.value }
            colorSource: Charts.SingleValueSource { value: pie.fill }
            backgroundColor: Kirigami.Theme.backgroundColor
            thickness: Math.max(3, pie.size * 0.19)
            filled: false
        }
        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: pie.label
            font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize - 1, pie.size / 4))
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
        property real size: 26   // floor/default; callers bind this to root.contentH
        implicitWidth: Math.max(16, size)
        implicitHeight: Math.max(16, size)

        Charts.PieChart {
            anchors.fill: parent
            range { automatic: true }
            indexingMode: Charts.Chart.IndexAllValues
            valueSources: [ Charts.ArraySource { array: mpie.values } ]
            colorSource: Charts.ArraySource { array: mpie.colors }
            backgroundColor: Kirigami.Theme.backgroundColor
            thickness: Math.max(3, mpie.size * 0.19)
            filled: false
        }
        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: mpie.label
            font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize - 1, mpie.size / 4))
            opacity: 0.9
        }
    }

    // ── horizontal bar, for the PSI/guard/disk grids ──────────────────────────
    component Bar : RowLayout {
        id: bar
        property string label: ""
        property real value: 0
        property color fill: Kirigami.Theme.highlightColor
        property real barWidth: 30    // floor/default; callers bind these off contentH
        property real barHeight: 6
        spacing: 3
        PlasmaComponents.Label {
            text: bar.label
            font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize, bar.barHeight * 1.4))
            opacity: 0.75
        }
        Rectangle {
            Layout.preferredWidth: Math.max(14, bar.barWidth)
            Layout.preferredHeight: Math.max(4, bar.barHeight)
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

    // ── metric lookups — clusters.json items name a "metric" id; these
    // functions are the other half of that data-driven split: JSON says
    // WHICH items a mode shows and in what order, these say what a given
    // metric id actually reads off snap/guardSnap and how to render it.
    function pieMetric(metric) {
        switch (metric) {
            case "cpu": return { value: root.snap.cpu || 0, label: root.pct0(root.snap.cpu), fill: root.heat(root.snap.cpu) };
            case "vram": {
                var v = root.vramPct();
                return { value: v || 0, label: v !== undefined ? root.pct0(v) : "--",
                         fill: v !== undefined ? root.heat(v) : Kirigami.Theme.disabledTextColor };
            }
            case "swap": return { value: root.snap.swap || 0, label: root.pct0(root.snap.swap), fill: root.heat(root.snap.swap) };
            case "slice": {
                var s = root.slicePct();
                return { value: s || 0, label: root.pct0(s), fill: root.heat(s) };
            }
            default: return { value: 0, label: "--", fill: Kirigami.Theme.disabledTextColor };
        }
    }
    function multiPieMetric(metric) {
        switch (metric) {
            case "mem": return { values: root.memLayers(), colors: root.memLayerColors(), label: root.memCentreText() };
            default: return { values: [], colors: [], label: "--" };
        }
    }
    // Fixed sub-metrics of the PSI 3x2 grid — structurally the same kind of
    // small labeled table as ptColumns/signalList/guardShortLabels above,
    // not a magic-number list: it names the 6 (category, avg10-field) pairs
    // PSI has, which is not itself something clusters.json's generic
    // {kind,metric} item schema can express any more cheaply.
    readonly property var psiRows: [
        { label: "Sc", cat: "cpu",    field: "some10" },
        { label: "Si", cat: "io",     field: "some10" },
        { label: "Sm", cat: "memory", field: "some10" },
        { label: "Fc", cat: "cpu",    field: "full10" },
        { label: "Fi", cat: "io",     field: "full10" },
        { label: "Fm", cat: "memory", field: "full10" }
    ]
    function bargridModel(metric) {
        switch (metric) {
            case "disks":
                return (root.snap.disks || []).map(function (d) {
                    return { label: root.shortMount(d.mount), value: d.pct || 0, fill: root.heat(d.pct) };
                });
            case "psi":
                return root.psiRows.map(function (r) {
                    var v = root.psi(r.cat, r.field);
                    return { label: r.label, value: v || 0, fill: root.heat(v) };
                });
            case "guard":
                return root.guardVoters().map(function (v) {
                    return { label: root.shortGuardLabel(v), value: root.guardRatio(v), fill: root.guardColor(v) };
                });
            default: return [];
        }
    }
    // Per-row bar height for a bargrid: rows are computed from the actual
    // item count and column count (never assumed), then contentH is divided
    // across them — this is what keeps the psi 3x2 / guard 4-col grids
    // inside the panel instead of overflowing it.
    function bargridBarHeight(metric, columns) {
        var count = root.bargridModel(metric).length;
        var cols = Math.max(1, columns || 1);
        var rows = Math.max(1, Math.ceil(count / cols));
        var rowH = (root.contentH - (rows - 1)) / rows;
        return Math.max(4, rowH * 0.55);
    }
    function rateItems(metric) {
        switch (metric) {
            case "disk_io": return [ { label: "R ", text: root.mbs(root.snap.disk_r) }, { label: "W ", text: root.mbs(root.snap.disk_w) } ];
            case "net_io": return [ { label: "↓", text: root.mbs(root.snap.net_rx) }, { label: "↑", text: root.mbs(root.snap.net_tx) } ];
            default: return [];
        }
    }
    function textMetric(metric) {
        switch (metric) {
            case "load": return root.two(root.snap.load1) + " " + root.two(root.snap.load5) + " " + root.two(root.snap.load15);
            case "proctable_head": {
                var t = root.snap.proc_table;
                if (!t || !t.length || !t[0]) return "procs --";
                // .toFixed() on an absent/null cpu_pct throws, which blanks
                // the whole binding — every other accessor in this file is
                // defensive (`|| 0`), this one needs to be too.
                return (t[0].name || "?") + " " + Number(t[0].cpu_pct || 0).toFixed(0) + "%";
            }
            default: return "";
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
        id: compactRoot
        // Width is genuinely content-driven — the panel gives a horizontal
        // applet whatever width it asks for, so implicitWidth stays derived
        // from the rendered content below.
        implicitWidth: content.implicitWidth
        // Height is NOT content-driven: the panel containment dictates it
        // (44px top / 60px bottom), and the widget must not fight that by
        // asking for a height computed from its own content — that was the
        // circular binding (implicitHeight -> contentH -> availH ->
        // compactRoot.height -> implicitHeight) that reproduced the exact
        // overflow this widget exists to fix. No implicitHeight binding
        // here at all; a small constant floor only matters before the panel
        // has assigned any geometry (e.g. a desktop-widget preview), and
        // even then it must not reference contentH/availH.
        implicitHeight: 16
        onClicked: root.expanded = !root.expanded

        // One-way: pushes the height the panel containment actually granted
        // THIS item into root.availH, which contentH (above) derives from.
        // `when: compactRoot.height > 0` keeps a stale/zero read from ever
        // landing during the brief window before the panel has laid this
        // item out; until then contentH's own floor (16) covers rendering.
        Binding {
            target: root
            property: "availH"
            value: compactRoot.height
            when: compactRoot.height > 0
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            spacing: root.clusterSpacing
            opacity: root.stale ? 0.45 : 1.0

            // Per-cluster title, small and low-opacity — every mode gets
            // one now instead of the old bare row of pies/bars.
            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.currentCluster.title || ""
                font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize - 1, root.titleH * 0.7))
                opacity: 0.6
                elide: Text.ElideRight
            }

            RowLayout {
                id: itemsRow
                Layout.alignment: Qt.AlignHCenter
                spacing: 6

                // One mode's cluster is one array of {kind, metric, columns?}
                // items from clusters.json; kind picks which Component below
                // renders it, metric picks which snap/guardSnap field(s) it
                // reads via the metric-lookup functions above.
                Repeater {
                    model: root.currentCluster.items || []
                    delegate: Loader {
                        id: itemLoader
                        readonly property var itemDef: modelData
                        sourceComponent: {
                            switch (itemDef.kind) {
                                case "pie": return pieDelegate;
                                case "multipie": return multipieDelegate;
                                case "bargrid": return bargridDelegate;
                                case "rate": return rateDelegate;
                                case "text": return textDelegate;
                                default: return null;
                            }
                        }

                        Component {
                            id: pieDelegate
                            Pie {
                                readonly property var m: root.pieMetric(itemLoader.itemDef.metric)
                                label: m.label; value: m.value; fill: m.fill
                                size: root.contentH
                            }
                        }
                        Component {
                            id: multipieDelegate
                            MultiPie {
                                readonly property var m: root.multiPieMetric(itemLoader.itemDef.metric)
                                label: m.label; values: m.values; colors: m.colors
                                size: root.contentH
                            }
                        }
                        Component {
                            id: bargridDelegate
                            GridLayout {
                                columns: Math.max(1, itemLoader.itemDef.columns || 1)
                                rowSpacing: 1
                                columnSpacing: 5
                                Repeater {
                                    model: root.bargridModel(itemLoader.itemDef.metric)
                                    delegate: Bar {
                                        label: modelData.label
                                        value: modelData.value
                                        fill: modelData.fill
                                        barHeight: root.bargridBarHeight(itemLoader.itemDef.metric, itemLoader.itemDef.columns || 1)
                                        barWidth: Math.max(18, root.contentH * 1.6)
                                    }
                                }
                            }
                        }
                        Component {
                            id: rateDelegate
                            RowLayout {
                                spacing: 4
                                Repeater {
                                    model: root.rateItems(itemLoader.itemDef.metric)
                                    delegate: PlasmaComponents.Label {
                                        text: modelData.label + modelData.text
                                        font.pointSize: root.fontPt
                                    }
                                }
                            }
                        }
                        Component {
                            id: textDelegate
                            PlasmaComponents.Label {
                                text: root.textMetric(itemLoader.itemDef.metric)
                                font.pointSize: root.fontPt
                            }
                        }
                    }
                }
            }
        }
    }

    // ── expanded: process table, every signal available ──────────────────────
    fullRepresentation: PlasmaExtras.Representation {
        // 26 gridUnits fits the simple (name/rss/pid/Signal) list every
        // other mode uses; proctable's 9 columns (8 + RSS) + a Signal button
        // + the sort ComboBox need more — widened rather than made
        // mode-conditional since fullRepresentation is created once and
        // Loader.active can't retroactively resize it.
        Layout.minimumWidth: Plasmoid.configuration.mode === "proctable"
            ? Kirigami.Units.gridUnit * 46 : Kirigami.Units.gridUnit * 26
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

        // Non-proctable instances (storage/mem/cpu/network/psi/guard) keep
        // the simple RSS-sorted list this always had — the rich sortable
        // table below is gated to mode==="proctable" only, same
        // Loader-on-mode pattern the compact clusters used to use.
        Loader {
            anchors.fill: parent
            active: Plasmoid.configuration.mode !== "proctable"
            visible: active
            sourceComponent: ListView {
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

        // proctable mode: sortable multi-column table over `proc_table`
        // (pid/name/user/cpu/mem/rss/read/write/runq_wait), clickable
        // headers with a hover highlight and a ▲/▼ direction indicator, PLUS
        // an explicit "Sort by" selector naming every sortable metric —
        // the header-click mechanism already existed but was undiscoverable
        // on its own, so both now drive the same ptSortKey/ptSortAsc state.
        // Each row also carries a per-row Signal menu offering every signal
        // in signalList — disabled with the reason shown when the daemon
        // marked the row `protected` (pid 1 / a protected slice), so a user
        // sees WHY a row can't be killed instead of a silent no-op.
        Loader {
            anchors.fill: parent
            active: Plasmoid.configuration.mode === "proctable"
            visible: active
            sourceComponent: ColumnLayout {
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    PlasmaComponents.Label { text: "Sort by:"; opacity: 0.75 }
                    PlasmaComponents.ComboBox {
                        id: ptSortCombo
                        Layout.preferredWidth: 220
                        model: root.ptSortableMetrics
                        textRole: "label"
                        currentIndex: {
                            for (var i = 0; i < root.ptSortableMetrics.length; i++)
                                if (root.ptSortableMetrics[i].key === root.ptSortKey) return i;
                            return 0;
                        }
                        onActivated: root.ptSelectSort(root.ptSortableMetrics[currentIndex].key)
                    }
                }

                RowLayout {
                    id: ptHeader
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.ptColumns
                        delegate: Item {
                            id: ptHeaderCell
                            Layout.preferredWidth: modelData.width
                            implicitHeight: ptHeaderLabel.implicitHeight + 4

                            Rectangle {
                                anchors.fill: parent
                                radius: 2
                                color: Kirigami.Theme.highlightColor
                                opacity: ptHeaderHover.containsMouse ? 0.25 : 0
                            }
                            PlasmaComponents.Label {
                                id: ptHeaderLabel
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                font.bold: root.ptSortKey === modelData.key
                                text: modelData.label + (root.ptSortKey === modelData.key ? (root.ptSortAsc ? " ▲" : " ▼") : "")
                            }
                            MouseArea {
                                id: ptHeaderHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.ptSort(modelData.key)
                            }
                        }
                    }
                    // Signal column header — no sort, just aligns with the
                    // per-row Signal buttons below.
                    Item { Layout.fillWidth: true }
                }

                ListView {
                    id: ptList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: root.ptSorted()
                    clip: true
                    spacing: 1
                    delegate: RowLayout {
                        id: ptRow
                        // Same shadowing hazard as procList above: capture
                        // pid/protected state up front, before the inner
                        // Repeater over signalList introduces its own
                        // modelData that would otherwise shadow this one.
                        property int ptPid: modelData.pid
                        property bool ptProtected: !!modelData.protected
                        property string ptReason: modelData.protected_reason || ""
                        width: ptList.width
                        spacing: 6
                        opacity: ptProtected ? 0.6 : 1.0

                        PlasmaComponents.Label { Layout.preferredWidth: 130; text: modelData.name; elide: Text.ElideRight }
                        PlasmaComponents.Label { Layout.preferredWidth: 70; text: modelData.user; elide: Text.ElideRight }
                        PlasmaComponents.Label { Layout.preferredWidth: 55; text: modelData.pid }
                        PlasmaComponents.Label { Layout.preferredWidth: 55; text: root.ptCellText(modelData, "cpu_pct") }
                        PlasmaComponents.Label { Layout.preferredWidth: 55; text: root.ptCellText(modelData, "mem_pct") }
                        PlasmaComponents.Label { Layout.preferredWidth: 65; text: root.ptCellText(modelData, "mem_rss_bytes") }
                        PlasmaComponents.Label { Layout.preferredWidth: 65; text: root.ptCellText(modelData, "read_bytes_per_s") }
                        PlasmaComponents.Label { Layout.preferredWidth: 65; text: root.ptCellText(modelData, "write_bytes_per_s") }
                        PlasmaComponents.Label { Layout.preferredWidth: 60; text: root.ptCellText(modelData, "runq_wait_pct") }

                        PlasmaComponents.Button {
                            Layout.fillWidth: true
                            text: ptRow.ptProtected ? "Protected" : "Signal"
                            icon.name: "process-stop"
                            enabled: !ptRow.ptProtected
                            // Shown even though the button is disabled: this
                            // is the "show the user why, not fail silently"
                            // requirement — a disabled button with no
                            // explanation is indistinguishable from a bug.
                            PlasmaComponents.ToolTip.visible: ptRow.ptProtected && hovered
                            PlasmaComponents.ToolTip.text: ptRow.ptReason
                            onClicked: ptSigMenu.open()
                            PlasmaComponents.Menu {
                                id: ptSigMenu
                                Repeater {
                                    model: root.signalList
                                    delegate: PlasmaComponents.MenuItem {
                                        text: modelData.label
                                        onTriggered: root.sendSignal(ptRow.ptPid, modelData.sig)
                                    }
                                }
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
