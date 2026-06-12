package com.diegonmarcos.comms

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Bundle
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.diegonmarcos.comms.updater.BundledForkInstaller
import com.diegonmarcos.comms.updater.FleetUpdater
import com.diegonmarcos.comms.updater.UpdateProgress
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.TimeZone

/**
 * Configs → About — a faithful port of Cloud-SuperApp's DevControlFragment
 * "About Cloud SuperApp" page, kept as an Activity. Same helper framework
 * (title / section / row / small / actionButton / fmtMillis / sizeStr) and the
 * same row-of-label/value, monospace-value visual style.
 *
 * Every fact is read from BuildConfig (baked from build.json / contract / data
 * at build time) + runtime PackageManager / ActivityManager — no hardcoded
 * facts. Long-press any value row to copy it; "Copy All Infos" at the bottom
 * dumps the entire page.
 */
class AboutActivity : AppCompatActivity() {

    /** Accumulator that mirrors everything written to the UI by title / section
     *  / row + small, so "Copy All Infos" can dump the whole page as text. */
    private var infoBuf = StringBuilder()

    /** Updates section live views — driven by UpdateProgress in onResume. */
    private lateinit var updateProgress: ProgressBar
    private lateinit var updateStatus: TextView

    /** Notifications runtime-permission request — re-renders on result so the
     *  Permissions row's ✓ / ✗ updates without a manual refresh. */
    private val notifPermLauncher =
        registerForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {
            Toast.makeText(this,
                if (it) "Notifications: granted" else "Notifications: denied",
                Toast.LENGTH_SHORT).show()
            recreate()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = getString(R.string.about_title)
        infoBuf = StringBuilder()

        val ctx = this
        val scroll = ScrollView(ctx).apply {
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
        }
        val column = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(16); setPadding(pad, pad, pad, pad)
        }
        scroll.addView(column)

        column.addView(title(ctx, getString(R.string.about_heading)))

        // ── About ──────────────────────────────────────────────────────
        section(ctx, column, "About") {
            row(ctx, it, "Name",         BuildConfig.APPLICATION_ID)
            row(ctx, it, "Version",      BuildConfig.VERSION_NAME)
            row(ctx, it, "Version code", BuildConfig.VERSION_CODE.toString())
            row(ctx, it, "Git sha",      BuildConfig.GIT_SHORT_SHA)
            row(ctx, it, "Built (UTC)",  BuildConfig.BUILD_TIMESTAMP)
            row(ctx, it, "Build type",   BuildConfig.BUILD_TYPE)
            row(ctx, it, "Debuggable",   BuildConfig.DEBUG.toString())
        }

        // ── Updater / GHCR ─────────────────────────────────────────────
        section(ctx, column, "Updater") {
            row(ctx, it, "Registry",  BuildConfig.GHCR_REGISTRY)
            row(ctx, it, "Namespace", BuildConfig.GHCR_NAMESPACE)
            row(ctx, it, "Image",     BuildConfig.GHCR_IMAGE)
            row(ctx, it, "Tag",       BuildConfig.AUTO_UPDATE_TAG)
            row(ctx, it, "Full URL",
                "${BuildConfig.GHCR_REGISTRY}/${BuildConfig.GHCR_NAMESPACE}/${BuildConfig.GHCR_IMAGE}:${BuildConfig.AUTO_UPDATE_TAG}")
            row(ctx, it, "Media type",     BuildConfig.GHCR_MEDIA_TYPE)
            row(ctx, it, "Check interval", "${BuildConfig.AUTO_UPDATE_INTERVAL_HOURS}h")
            row(ctx, it, "Enabled",        BuildConfig.AUTO_UPDATE_ENABLED.toString())
            row(ctx, it, "Install mode",   BuildConfig.AU_INSTALL_MODE)
            row(ctx, it, "Require unmetered", BuildConfig.AU_REQUIRE_UNMETERED.toString())
            row(ctx, it, "Require charging",  BuildConfig.AU_REQUIRE_CHARGING.toString())
        }

        // ── APK (same rows as superapp's APK section) ──────────────────
        section(ctx, column, "APK") {
            @Suppress("DEPRECATION")
            val info = packageManager.getPackageInfo(packageName, 0)
            // PackageInfo.applicationInfo is @Nullable as of API 35 — fall back
            // to "—" so the row still renders.
            val path = info.applicationInfo?.sourceDir ?: "—"
            val size = runCatching { java.io.File(path).length() }.getOrDefault(0L)
            row(ctx, it, "Path",       path)
            row(ctx, it, "Size",       sizeStr(size))
            row(ctx, it, "Installed",  fmtMillis(info.firstInstallTime))
            row(ctx, it, "Updated",    fmtMillis(info.lastUpdateTime))
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                val src = runCatching { packageManager.getInstallSourceInfo(packageName) }.getOrNull()
                row(ctx, it, "Installed by", src?.installingPackageName ?: "—")
            } else {
                @Suppress("DEPRECATION")
                row(ctx, it, "Installed by",
                    runCatching { packageManager.getInstallerPackageName(packageName) }.getOrNull() ?: "—")
            }
        }

        // ── Device / stack ─────────────────────────────────────────────
        section(ctx, column, "Device / stack") {
            row(ctx, it, "Manufacturer", android.os.Build.MANUFACTURER)
            row(ctx, it, "Model",        android.os.Build.MODEL)
            row(ctx, it, "Brand",        android.os.Build.BRAND)
            row(ctx, it, "Device",       android.os.Build.DEVICE)
            row(ctx, it, "Hardware",     android.os.Build.HARDWARE)
            row(ctx, it, "Android",      "${android.os.Build.VERSION.RELEASE} (SDK ${android.os.Build.VERSION.SDK_INT})")
            row(ctx, it, "ABIs",         android.os.Build.SUPPORTED_ABIS.joinToString(", "))
            row(ctx, it, "Locale",       java.util.Locale.getDefault().toLanguageTag())
        }

        // ── Storage (same breakdown as superapp's Storage section) ─────
        section(ctx, column, "Storage") {
            @Suppress("DEPRECATION")
            val pkg = packageManager.getPackageInfo(packageName, 0)
            val appInfo    = pkg.applicationInfo
            val apkBytes   = runCatching { java.io.File(appInfo?.sourceDir ?: "").length() }.getOrDefault(0L)
            val dataDir    = appInfo?.dataDir?.let { d -> java.io.File(d) } ?: dataDir
            val cacheBytes = dirSize(cacheDir)
            // dataDir contains cacheDir; subtract to get pure "data".
            val dataBytes  = (dirSize(dataDir) - cacheBytes).coerceAtLeast(0L)
            val totalBytes = apkBytes + dataBytes + cacheBytes

            row(ctx, it, "Files dir",  filesDir.absolutePath)
            row(ctx, it, "Cache dir",  cacheDir.absolutePath)
            row(ctx, it, "Data root",  dataDir.absolutePath)
            row(ctx, it, "External",   getExternalFilesDir(null)?.absolutePath ?: "—")
            it.addView(small(ctx, "Breakdown — same buckets Android system settings shows:"))
            row(ctx, it, "Aplicación", sizeStr(apkBytes))
            row(ctx, it, "Datos",      sizeStr(dataBytes))
            row(ctx, it, "Caché",      sizeStr(cacheBytes))
            row(ctx, it, "Total",      sizeStr(totalBytes))
        }

        // ── IPC contract ───────────────────────────────────────────────
        section(ctx, column, "IPC contract") {
            row(ctx, it, "Contract",   "v${BuildConfig.IPC_VERSION}")
            row(ctx, it, "Authority",  BuildConfig.IPC_AUTHORITY)
            row(ctx, it, "Permission", BuildConfig.IPC_PERMISSION)
            row(ctx, it, "Open action", BuildConfig.LAUNCH_ACTION)
            it.addView(small(ctx, "Signature-gated — all constellation APKs share one signing key."))
        }

        // ── Constellation ──────────────────────────────────────────────
        section(ctx, column, "Constellation") {
            val forks = runCatching {
                JSONObject(String(Base64.decode(BuildConfig.FORKS_JSON_B64, Base64.DEFAULT)))
            }.getOrDefault(JSONObject())
            for (e in FleetUpdater.fleet) {
                val installed = e.installedVersion(ctx)
                val state = when {
                    e.blocked -> "blocked"
                    installed != null -> "v$installed"
                    BundledForkInstaller.hasBundle(ctx, e.label) -> "bundled · tap to install"
                    else -> "not bundled yet"
                }
                val name = if (e.label == "hub") "Cloud-Comms (hub)"
                           else forks.optJSONObject(e.label)?.optString("label")?.ifBlank { null } ?: e.label
                row(ctx, it, name, state)
                if (e.label == "hub") {
                    row(ctx, it, "  image", e.image)
                } else forks.optJSONObject(e.label)?.let { f ->
                    val pin = f.optString("pinned_tag").ifBlank { "—" }
                    row(ctx, it, "  license/runtime",
                        "${f.optString("license").ifBlank { "—" }} · ${f.optString("runtime").ifBlank { "—" }} · pin $pin")
                    row(ctx, it, "  bundled?",
                        if (BundledForkInstaller.hasBundle(ctx, e.label)) "yes" else "no")
                }
                row(ctx, it, "  app id", e.appId)
            }
        }

        // ── Permissions ────────────────────────────────────────────────
        section(ctx, column, "Permissions") {
            it.addView(small(ctx, "Manifest permissions — States: ✓ Granted · ✗ Denied. Normal/signature perms are auto-granted at install; runtime perms (notifications on API 33+) need a prompt."))
            // The hub's ACTUAL manifest permissions (see AndroidManifest.xml).
            val perms = listOf(
                "INTERNET"                to "android.permission.INTERNET",
                "Network state"           to "android.permission.ACCESS_NETWORK_STATE",
                "Wi-Fi state"             to "android.permission.ACCESS_WIFI_STATE",
                "Install packages"        to "android.permission.REQUEST_INSTALL_PACKAGES",
                "Post notifications"      to "android.permission.POST_NOTIFICATIONS",
                "IPC (signature)"         to BuildConfig.IPC_PERMISSION,
            )
            for ((label, perm) in perms) {
                row(ctx, it, label, permissionState(perm))
            }
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                it.addView(actionButton(ctx, "Request notifications") {
                    notifPermLauncher.launch("android.permission.POST_NOTIFICATIONS")
                })
            } else {
                it.addView(small(ctx, "Pre-API 33 — notifications are granted by default."))
            }
            it.addView(actionButton(ctx, "Open System App Settings") { openAppSettings() })
        }

        // ── Battery & Usage (ported from superapp's About) ─────────────
        section(ctx, column, "Battery & Usage") {
            // Everything in this block is what the app CAN read about
            // itself without privileged permissions. Per-app battery mAh
            // + screen-on / background time split / wakelocks count etc.
            // live in BatteryStatsManager which is system-only.
            @Suppress("DEPRECATION")
            val pkg = packageManager.getPackageInfo(packageName, 0)
            val myUid = applicationInfo.uid

            // App-side crash count — files under getExternalFilesDir/crashes/
            // (crash-<ts>.txt, superapp's CrashLogger layout). The hub has no
            // crash logger yet so this degrades to 0 / "—" until one writes there.
            val crashDir = File(getExternalFilesDir(null), "crashes")
            val crashes  = crashDir.listFiles { f -> f.name.startsWith("crash-") }?.size ?: 0
            val mostRecent = crashDir.listFiles { f -> f.name.startsWith("crash-") }
                ?.maxByOrNull { it.lastModified() }
            row(ctx, it, "Crash count",  crashes.toString())
            row(ctx, it, "Last crash",   mostRecent?.let { fmtMillis(it.lastModified()) } ?: "—")
            row(ctx, it, "Crashes dir",  crashDir.absolutePath)

            // Process uptime since this process was forked. Superapp anchors
            // on AppProcessUptime.startedAtElapsed (set in Application
            // onCreate); the hub uses the framework equivalent (API 24+) —
            // elapsedRealtime at process start — so the row stays live
            // without any superapp module.
            val uptimeMs = android.os.SystemClock.elapsedRealtime() -
                android.os.Process.getStartElapsedRealtime()
            row(ctx, it, "Process uptime", fmtDuration(uptimeMs))
            row(ctx, it, "First install",  fmtMillis(pkg.firstInstallTime))
            row(ctx, it, "Last update",    fmtMillis(pkg.lastUpdateTime))

            // Network bytes RX/TX since boot (TrafficStats is per-UID;
            // resets on reboot). Captures all sockets this UID has used.
            val rx = android.net.TrafficStats.getUidRxBytes(myUid)
            val tx = android.net.TrafficStats.getUidTxBytes(myUid)
            val rxMobile = android.net.TrafficStats.getMobileRxBytes()
            val txMobile = android.net.TrafficStats.getMobileTxBytes()
            row(ctx, it, "Net RX (all)",    sizeStr(if (rx < 0) 0L else rx))
            row(ctx, it, "Net TX (all)",    sizeStr(if (tx < 0) 0L else tx))
            row(ctx, it, "Mobile RX (UID)", if (rxMobile < 0) "—" else sizeStr(rxMobile))
            row(ctx, it, "Mobile TX (UID)", if (txMobile < 0) "—" else sizeStr(txMobile))

            // Per-app foreground / background screen time needs
            // PACKAGE_USAGE_STATS (Usage Access) — the hub doesn't declare
            // it, so the rows degrade instead of querying UsageStatsManager.
            row(ctx, it, "Screen-on",   "—")
            row(ctx, it, "Background",  "—")
            row(ctx, it, "Total used",  "—")
            it.addView(small(ctx, "Screen-time rows need PACKAGE_USAGE_STATS (Usage Access) — not declared by the hub."))
            // Since-last-charge analytics (%/h rate, ETA, live drain W,
            // battery temp / cycle count via the session anchor) are computed
            // by superapp's BatterySessionStats module — not available here.
            it.addView(small(ctx, "Since-last-charge analytics (%/h rate, ETA, live drain W) live in superapp's BatterySessionStats — not available in the hub. Battery (deep) below carries the full BatteryManager surface."))
            it.addView(small(ctx, "Battery-stats internals (mAh per-component, wakelocks, wakeups) are system-only."))
        }

        // ── Memory & CPU Usage ─────────────────────────────────────────
        section(ctx, column, "Memory & CPU Usage") {
            // All metrics are process-attributable + readable WITHOUT any
            // privileged permission. JVM heap from Runtime; PSS from
            // Debug.MemoryInfo (Android's accounting for shared-page
            // proportional set size); RSS from /proc/self/statm (raw
            // kernel view). System totals come from ActivityManager.
            // CPU comes from /proc/self/stat (utime + stime in jiffies)
            // normalised against process wall-time for an avg %.
            val rt = Runtime.getRuntime()

            val heapMax   = rt.maxMemory()
            val heapTotal = rt.totalMemory()
            val heapFree  = rt.freeMemory()
            val heapUsed  = heapTotal - heapFree
            val heapPct   = if (heapMax > 0) (heapUsed * 100 / heapMax).toInt() else -1
            row(ctx, it, "JVM heap used",
                "${sizeStr(heapUsed)} / ${sizeStr(heapMax)}" +
                    (if (heapPct >= 0) " ($heapPct%)" else ""))
            row(ctx, it, "JVM heap total", sizeStr(heapTotal))
            row(ctx, it, "JVM heap free",  sizeStr(heapFree))

            val mi = android.os.Debug.MemoryInfo()
            android.os.Debug.getMemoryInfo(mi)
            row(ctx, it, "PSS total",     sizeStr(mi.totalPss.toLong()        * 1024L))
            row(ctx, it, "PSS dalvik",    sizeStr(mi.dalvikPss.toLong()       * 1024L))
            row(ctx, it, "PSS native",    sizeStr(mi.nativePss.toLong()       * 1024L))
            row(ctx, it, "PSS other",     sizeStr(mi.otherPss.toLong()        * 1024L))
            row(ctx, it, "Private dirty", sizeStr(mi.totalPrivateDirty.toLong() * 1024L))

            // RSS via /proc/self/statm field 2 (resident pages).
            val pageSize = runCatching {
                android.system.Os.sysconf(android.system.OsConstants._SC_PAGESIZE)
            }.getOrDefault(4096L)
            val rssBytes = runCatching {
                val parts = File("/proc/self/statm").readText().trim().split(' ')
                parts.getOrNull(1)?.toLongOrNull()?.let { it * pageSize } ?: -1L
            }.getOrDefault(-1L)
            row(ctx, it, "RSS", if (rssBytes < 0) "—" else sizeStr(rssBytes))

            val am = getSystemService(Context.ACTIVITY_SERVICE)
                as? android.app.ActivityManager
            val sysMi = android.app.ActivityManager.MemoryInfo()
            am?.getMemoryInfo(sysMi)
            row(ctx, it, "System avail",      sizeStr(sysMi.availMem))
            row(ctx, it, "System total",      sizeStr(sysMi.totalMem))
            row(ctx, it, "System low-memory", sysMi.lowMemory.toString())
            row(ctx, it, "Heap class limit",  am?.memoryClass?.let { "$it MB" } ?: "—")
            row(ctx, it, "Heap class (large)",
                am?.largeMemoryClass?.let { "$it MB" } ?: "—")

            // CPU: utime (field 14) + stime (field 15) in jiffies. The
            // comm field is parenthesised and may contain spaces — strip
            // it before tokenising so field indices stay aligned.
            val statRaw = runCatching { File("/proc/self/stat").readText() }.getOrNull()
            val fields = statRaw?.let { raw ->
                val open  = raw.indexOf('(')
                val close = raw.lastIndexOf(')')
                if (open < 0 || close < 0 || close <= open) null
                else (raw.substring(0, open) + raw.substring(close + 1))
                    .trim().split(Regex("\\s+"))
            }
            val tck   = runCatching {
                android.system.Os.sysconf(android.system.OsConstants._SC_CLK_TCK)
            }.getOrDefault(100L)
            val utime = fields?.getOrNull(13)?.toLongOrNull() ?: -1L
            val stime = fields?.getOrNull(14)?.toLongOrNull() ?: -1L
            val cpuJif = if (utime < 0 || stime < 0) -1L else utime + stime

            // Wall-time anchor: superapp uses AppProcessUptime; the hub uses
            // the framework process-start clock (same semantics).
            val uptimeMs = android.os.SystemClock.elapsedRealtime() -
                android.os.Process.getStartElapsedRealtime()
            val uptimeSec = uptimeMs / 1000.0

            row(ctx, it, "CPU user-time",
                if (utime < 0 || tck <= 0) "—"
                else "%.2fs".format(utime.toDouble() / tck))
            row(ctx, it, "CPU sys-time",
                if (stime < 0 || tck <= 0) "—"
                else "%.2fs".format(stime.toDouble() / tck))
            row(ctx, it, "CPU total",
                if (cpuJif < 0 || tck <= 0) "—"
                else "%.2fs".format(cpuJif.toDouble() / tck))

            val cores = rt.availableProcessors()
            val avgPctSingle = if (cpuJif < 0 || uptimeSec <= 0 || tck <= 0) -1.0
                else (cpuJif.toDouble() / tck / uptimeSec) * 100.0
            val avgPctPerCore = if (avgPctSingle < 0 || cores <= 0) -1.0
                else avgPctSingle / cores
            row(ctx, it, "CPU avg % (1-thread)",
                if (avgPctSingle < 0) "—" else "%.2f%%".format(avgPctSingle))
            row(ctx, it, "CPU avg % (per-core)",
                if (avgPctPerCore < 0) "—" else "%.2f%%".format(avgPctPerCore))
            row(ctx, it, "Cores online", cores.toString())

            // ── Phone storage ─────────────────────────────────────
            // StatFs against the data partition is the right anchor —
            // that's where the app, its caches, and DB live; "phone
            // storage" colloquially means user-data partition free space.
            // External / SD is separate but reported next to it so the
            // user has both numbers in one place.
            val dataDirPath = android.os.Environment.getDataDirectory().absolutePath
            val (dataFree, dataTotal) = statFsBytes(dataDirPath)
            val dataPct = if (dataTotal > 0) ((dataTotal - dataFree) * 100 / dataTotal).toInt() else -1
            row(ctx, it, "Data free",
                "${sizeStr(dataFree)} / ${sizeStr(dataTotal)}" +
                    (if (dataPct >= 0) " (${100 - dataPct}% free)" else ""))

            val extDir = getExternalFilesDir(null)?.absolutePath
            if (extDir != null) {
                val (extFree, extTotal) = statFsBytes(extDir)
                row(ctx, it, "External free",
                    "${sizeStr(extFree)} / ${sizeStr(extTotal)}")
            }

            // ── Phone swap (zRAM / disk) ──────────────────────────
            // /proc/meminfo SwapTotal + SwapFree are kB, space-padded.
            // Some kernels disable swap entirely → SwapTotal:0; report
            // "disabled" so the row isn't misread as "everything's used".
            val (swapTotal, swapFree) = readSwapBytes()
            val swapUsed = if (swapTotal < 0 || swapFree < 0) -1L else swapTotal - swapFree
            row(ctx, it, "Swap total",
                if (swapTotal < 0) "—"
                else if (swapTotal == 0L) "disabled"
                else sizeStr(swapTotal))
            row(ctx, it, "Swap free",
                if (swapFree < 0 || swapTotal == 0L) "—" else sizeStr(swapFree))
            row(ctx, it, "Swap used",
                if (swapUsed < 0 || swapTotal == 0L) "—" else sizeStr(swapUsed))

            it.addView(small(ctx, "PSS = process-attributable RSS after sharing. JVM heap is the growable section of the Dalvik PSS bucket. CPU avg % is utime+stime / wall-time × 100 — 1-thread (100% = one core saturated) or per-core (100% = ALL cores saturated). Sustained > 50% with the screen off may indicate a background work leak. Storage = data partition (where the app + caches live). Swap is typically zRAM on Android — counts AGAINST physical RAM but appears as virtual."))
        }

        // ── Battery (deep) ─────────────────────────────────────────────
        section(ctx, column, "Battery (deep)") {
            // Direct read from sticky battery intent + BatteryManager
            // properties. cycle_count is the Android 14+ goodie.
            val bm = getSystemService(Context.BATTERY_SERVICE) as? android.os.BatteryManager
            val battery = runCatching {
                registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
            }.getOrNull()
            val level   = battery?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL,  -1) ?: -1
            val scale   = battery?.getIntExtra(android.os.BatteryManager.EXTRA_SCALE,  -1) ?: -1
            val status  = battery?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
            val plugged = battery?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, -1) ?: -1
            val tech    = battery?.getStringExtra(android.os.BatteryManager.EXTRA_TECHNOLOGY) ?: "—"
            val tempDeci = battery?.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
            val mvolts  = battery?.getIntExtra(android.os.BatteryManager.EXTRA_VOLTAGE, -1) ?: -1
            val health  = battery?.getIntExtra(android.os.BatteryManager.EXTRA_HEALTH, -1) ?: -1

            val pct = if (level >= 0 && scale > 0) "%d %%".format(level * 100 / scale) else "—"
            val statusStr = when (status) {
                android.os.BatteryManager.BATTERY_STATUS_CHARGING    -> "Charging"
                android.os.BatteryManager.BATTERY_STATUS_DISCHARGING -> "Discharging"
                android.os.BatteryManager.BATTERY_STATUS_FULL        -> "Full"
                android.os.BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "Not charging"
                else -> "—"
            }
            val pluggedStr = when (plugged) {
                android.os.BatteryManager.BATTERY_PLUGGED_AC       -> "AC"
                android.os.BatteryManager.BATTERY_PLUGGED_USB      -> "USB"
                android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
                0 -> "Unplugged"
                else -> "—"
            }
            val healthStr = when (health) {
                android.os.BatteryManager.BATTERY_HEALTH_GOOD              -> "Good"
                android.os.BatteryManager.BATTERY_HEALTH_OVERHEAT          -> "Overheat"
                android.os.BatteryManager.BATTERY_HEALTH_DEAD              -> "Dead"
                android.os.BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE      -> "Over voltage"
                android.os.BatteryManager.BATTERY_HEALTH_UNSPECIFIED_FAILURE -> "Failure"
                android.os.BatteryManager.BATTERY_HEALTH_COLD              -> "Cold"
                else -> "—"
            }
            row(ctx, it, "Level",       pct)
            row(ctx, it, "Status",      statusStr)
            row(ctx, it, "Power source", pluggedStr)
            row(ctx, it, "Health",      healthStr)
            row(ctx, it, "Technology",  tech)
            row(ctx, it, "Temperature", if (tempDeci >= 0) "%.1f °C".format(tempDeci / 10.0) else "—")
            row(ctx, it, "Voltage",     if (mvolts >= 0) "%d mV".format(mvolts) else "—")

            // BatteryManager properties: instant µA / µAh / µWh. cycle
            // count is API 34+ (constant value 7); query optimistically.
            if (bm != null) {
                val curNowMicro = runCatching { bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CURRENT_NOW) }.getOrDefault(0)
                val curAvgMicro = runCatching { bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CURRENT_AVERAGE) }.getOrDefault(0)
                val chargeCounterUah = runCatching { bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER) }.getOrDefault(0)
                val energyCounterNwh = runCatching { bm.getLongProperty(android.os.BatteryManager.BATTERY_PROPERTY_ENERGY_COUNTER) }.getOrDefault(0L)
                row(ctx, it, "Current (now)", if (curNowMicro != Int.MIN_VALUE) "%d mA".format(curNowMicro / 1000) else "—")
                row(ctx, it, "Current (avg)", if (curAvgMicro != Int.MIN_VALUE) "%d mA".format(curAvgMicro / 1000) else "—")
                row(ctx, it, "Charge counter", if (chargeCounterUah > 0) "%d mAh".format(chargeCounterUah / 1000) else "—")
                row(ctx, it, "Energy counter", if (energyCounterNwh > 0) "%d µWh".format(energyCounterNwh) else "—")
                if (android.os.Build.VERSION.SDK_INT >= 34) {
                    // BATTERY_PROPERTY_CYCLE_COUNT = 7 (API 34+).
                    val cycles = runCatching { bm.getIntProperty(7) }.getOrDefault(-1)
                    row(ctx, it, "Cycle count", if (cycles >= 0) cycles.toString() else "—")
                }
                val remainingMs = runCatching { bm.computeChargeTimeRemaining() }.getOrDefault(-1L)
                if (remainingMs > 0) row(ctx, it, "Time to full", fmtDuration(remainingMs))
            }
        }

        // ── Network ────────────────────────────────────────────────────
        section(ctx, column, "Network") {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            val active = cm?.activeNetwork
            val caps = active?.let { runCatching { cm?.getNetworkCapabilities(it) }.getOrNull() }
            val link = active?.let { runCatching { cm?.getLinkProperties(it) }.getOrNull() }

            val transports = mutableListOf<String>()
            caps?.let { c ->
                if (c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI))      transports.add("Wi-Fi")
                if (c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR))  transports.add("Cellular")
                if (c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET))  transports.add("Ethernet")
                if (c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN))       transports.add("VPN")
                if (c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_BLUETOOTH)) transports.add("Bluetooth")
            }
            row(ctx, it, "Transport",     if (transports.isEmpty()) "—" else transports.joinToString(", "))
            row(ctx, it, "Validated",     caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)?.toString() ?: "—")
            row(ctx, it, "Captive portal", caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)?.toString() ?: "—")
            row(ctx, it, "Metered",       cm?.isActiveNetworkMetered?.toString() ?: "—")
            caps?.let { c ->
                row(ctx, it, "Link down",     "${c.linkDownstreamBandwidthKbps} kbps")
                row(ctx, it, "Link up",       "${c.linkUpstreamBandwidthKbps} kbps")
            }
            link?.let { lp ->
                row(ctx, it, "Iface",  lp.interfaceName ?: "—")
                row(ctx, it, "MTU",    lp.mtu.toString())
                row(ctx, it, "DNS",    lp.dnsServers.joinToString(", ") { it.hostAddress ?: "" }.ifBlank { "—" })
                val v4 = lp.linkAddresses.mapNotNull { la -> la.address.hostAddress }.filter { ":" !in it }
                val v6 = lp.linkAddresses.mapNotNull { la -> la.address.hostAddress }.filter { ":" in it }
                row(ctx, it, "IPv4",   v4.joinToString(", ").ifBlank { "—" })
                row(ctx, it, "IPv6",   v6.joinToString(", ").ifBlank { "—" })
                val gw = lp.routes.firstOrNull { r -> r.isDefaultRoute }?.gateway?.hostAddress
                row(ctx, it, "Default gw", gw ?: "—")
            }
        }

        // ── Wi-Fi ──────────────────────────────────────────────────────
        section(ctx, column, "Wi-Fi") {
            // SSID/BSSID require ACCESS_FINE_LOCATION on Android 10+
            // AND a connected Wi-Fi network. The hub only declares
            // ACCESS_WIFI_STATE (deliberately no location), so SSID
            // comes back as "<unknown ssid>" — surfaced as the same
            // user-facing hint superapp shows pre-grant.
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager
            if (wm == null || !wm.isWifiEnabled) {
                it.addView(small(ctx, "Wi-Fi is off."))
            } else {
                @Suppress("DEPRECATION")
                val info = runCatching { wm.connectionInfo }.getOrNull()
                if (info == null) {
                    it.addView(small(ctx, "No Wi-Fi connection info."))
                } else {
                    val ssid = info.ssid?.trim('"').orEmpty()
                    row(ctx, it, "SSID",       if (ssid.isBlank() || ssid == "<unknown ssid>") "Needs location permission" else ssid)
                    row(ctx, it, "BSSID",      info.bssid ?: "—")
                    row(ctx, it, "RSSI",       "${info.rssi} dBm")
                    row(ctx, it, "Link speed", "${info.linkSpeed} Mbps")
                    row(ctx, it, "Tx speed",   "${info.txLinkSpeedMbps} Mbps")
                    if (android.os.Build.VERSION.SDK_INT >= 29) {
                        row(ctx, it, "Rx speed", "${info.rxLinkSpeedMbps} Mbps")
                    }
                    row(ctx, it, "Frequency",  "${info.frequency} MHz")
                    row(ctx, it, "Hidden SSID", info.hiddenSSID.toString())
                }
            }
        }

        // ── SoC / CPU ──────────────────────────────────────────────────
        section(ctx, column, "SoC / CPU") {
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                row(ctx, it, "SoC mfr",   android.os.Build.SOC_MANUFACTURER)
                row(ctx, it, "SoC model", android.os.Build.SOC_MODEL)
            }
            row(ctx, it, "Bootloader", android.os.Build.BOOTLOADER)
            @Suppress("DEPRECATION")
            row(ctx, it, "Radio",      android.os.Build.getRadioVersion() ?: "—")
            row(ctx, it, "Board",      android.os.Build.BOARD)
            row(ctx, it, "Fingerprint", android.os.Build.FINGERPRINT)
            row(ctx, it, "CPU cores",  Runtime.getRuntime().availableProcessors().toString())
            val cpuModel = runCatching {
                File("/proc/cpuinfo").useLines { lines ->
                    lines.firstOrNull { it.startsWith("Hardware") || it.contains("model name") }
                        ?.substringAfter(':')?.trim()
                }
            }.getOrNull()
            row(ctx, it, "CPU model",  cpuModel ?: "—")
            val curFreq = runCatching {
                File("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq").readText().trim().toLong()
            }.getOrNull()
            row(ctx, it, "Cur freq",   curFreq?.let { "%d MHz".format(it / 1000) } ?: "—")
            val gov = runCatching {
                File("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor").readText().trim()
            }.getOrNull()
            row(ctx, it, "Governor",   gov ?: "—")
        }

        // ── Thermal zones ──────────────────────────────────────────────
        section(ctx, column, "Thermal zones") {
            val zones = runCatching {
                File("/sys/class/thermal").listFiles { f -> f.name.startsWith("thermal_zone") }
                    ?.sortedBy { it.name }
            }.getOrNull()
            if (zones.isNullOrEmpty()) {
                it.addView(small(ctx, "No thermal zones readable (kernel restricts /sys/class/thermal on most modern devices)."))
            } else {
                for (z in zones) {
                    val type = runCatching { File(z, "type").readText().trim() }.getOrDefault(z.name)
                    val tempMilliC = runCatching { File(z, "temp").readText().trim().toLong() }.getOrDefault(0L)
                    row(ctx, it, z.name, "$type — %.1f °C".format(tempMilliC / 1000.0))
                }
            }
        }

        // SYSFS-PROC — the no-perm kernel-telemetry dump. Every field
        // here comes from a world-readable /sys or /proc file (the
        // same path AccuBattery, Termux's top, and friends use). No
        // DUMP, no QUERY_ALL_PACKAGES, no signature perm required.
        // The reader (SysfsProc.kt, ported from superapp) returns
        // (key, formatted-value) pairs per subsystem; we paint
        // sub-group headers via small() so the section is one big
        // scrollable table the user can long-press individual rows
        // to copy.
        section(ctx, column, "SYSFS-PROC") {
            it.addView(small(ctx, "Raw kernel-side telemetry — no runtime permission needed. World-readable /sys/class/* and /proc/* paths. Use this as the audit surface; promote interesting rows to dedicated UI elsewhere."))

            it.addView(small(ctx, "── /sys/class/power_supply/battery/"))
            for ((k, v) in SysfsProc.battery()) row(ctx, it, k, v)

            it.addView(small(ctx, "── /sys/class/power_supply/{usb,ac,wireless,main}/"))
            val chargerRows = SysfsProc.chargers()
            if (chargerRows.isEmpty()) it.addView(small(ctx, "(no charger nodes readable)"))
            for ((k, v) in chargerRows) row(ctx, it, k, v)

            it.addView(small(ctx, "── /proc/loadavg + /proc/uptime  (CPU load in seconds)"))
            for ((k, v) in SysfsProc.cpuLoadRows()) row(ctx, it, k, v)

            it.addView(small(ctx, "── /proc/stat  (cumulative jiffies → seconds, ALL cores)"))
            for ((k, v) in SysfsProc.procStatRows()) row(ctx, it, k, v)

            it.addView(small(ctx, "── /sys/devices/system/cpu/cpu*/cpufreq/"))
            for ((k, v) in SysfsProc.cpuFreqs()) row(ctx, it, k, v)

            it.addView(small(ctx, "── /sys/class/thermal/thermal_zone*/"))
            val thermalRows = SysfsProc.thermal()
            if (thermalRows.isEmpty()) it.addView(small(ctx, "(no zones readable — vendor restriction)"))
            for ((k, v) in thermalRows) row(ctx, it, k, v)

            it.addView(small(ctx, "── /proc/meminfo  (selected)"))
            for ((k, v) in SysfsProc.memInfo()) row(ctx, it, k, v)

            it.addView(small(ctx, "── /sys/class/net/*/statistics/"))
            for ((k, v) in SysfsProc.network()) row(ctx, it, k, v)

            it.addView(small(ctx, "── /proc/diskstats"))
            val diskRows = SysfsProc.diskstats()
            if (diskRows.isEmpty()) it.addView(small(ctx, "(no diskstats readable)"))
            for ((k, v) in diskRows) row(ctx, it, k, v)

            it.addView(small(ctx, "── /proc/self/  (this app's own kernel-side stats)"))
            for ((k, v) in SysfsProc.selfProc()) row(ctx, it, k, v)
        }

        // ── Kernel / OS ────────────────────────────────────────────────
        section(ctx, column, "Kernel / OS") {
            row(ctx, it, "Kernel",   System.getProperty("os.version") ?: "—")
            row(ctx, it, "Security patch", android.os.Build.VERSION.SECURITY_PATCH)
            row(ctx, it, "Codename", android.os.Build.VERSION.CODENAME)
            row(ctx, it, "Incremental", android.os.Build.VERSION.INCREMENTAL)
            row(ctx, it, "/proc/version", runCatching { File("/proc/version").readText().trim() }.getOrDefault("—"))
            row(ctx, it, "VM",       "${System.getProperty("java.vm.name")} ${System.getProperty("java.vm.version")}")
            row(ctx, it, "VM heap",  "${sizeStr(Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory())} / ${sizeStr(Runtime.getRuntime().maxMemory())}")
            val nativeHeap = android.os.Debug.getNativeHeapAllocatedSize()
            row(ctx, it, "Native heap", sizeStr(nativeHeap))
        }

        // ── Memory (system + per-process, superapp's second Memory) ────
        section(ctx, column, "Memory") {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            val mi = android.app.ActivityManager.MemoryInfo()
            am?.getMemoryInfo(mi)
            row(ctx, it, "Total RAM",  sizeStr(mi.totalMem))
            row(ctx, it, "Available",  sizeStr(mi.availMem))
            row(ctx, it, "Threshold",  sizeStr(mi.threshold))
            row(ctx, it, "Low memory", mi.lowMemory.toString())
            val pids = intArrayOf(android.os.Process.myPid())
            val procInfo = runCatching { am?.getProcessMemoryInfo(pids) }.getOrNull()?.firstOrNull()
            if (procInfo != null) {
                row(ctx, it, "App PSS",  sizeStr(procInfo.totalPss * 1024L))
                row(ctx, it, "Java heap", sizeStr(procInfo.getMemoryStat("summary.java-heap")?.toLongOrNull()?.times(1024L) ?: 0L))
                row(ctx, it, "Native heap (proc)", sizeStr(procInfo.getMemoryStat("summary.native-heap")?.toLongOrNull()?.times(1024L) ?: 0L))
            }
            val fdCount = runCatching {
                File("/proc/self/fd").listFiles()?.size ?: 0
            }.getOrDefault(0)
            row(ctx, it, "Open FDs", fdCount.toString())
            row(ctx, it, "Threads",  Thread.activeCount().toString())
        }

        // ── Display ────────────────────────────────────────────────────
        section(ctx, column, "Display") {
            val wm = getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager
            val dm = resources.displayMetrics
            row(ctx, it, "Resolution", "${dm.widthPixels} × ${dm.heightPixels}")
            row(ctx, it, "Density",    "${dm.density}x · ${dm.densityDpi} dpi")
            @Suppress("DEPRECATION")
            val display = wm?.defaultDisplay
            row(ctx, it, "Refresh",    display?.refreshRate?.let { "%.1f Hz".format(it) } ?: "—")
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                val modes = display?.supportedModes?.map { "%.0f Hz @ %dx%d".format(it.refreshRate, it.physicalWidth, it.physicalHeight) }
                row(ctx, it, "Modes", modes?.joinToString(", ") ?: "—")
            }
            if (android.os.Build.VERSION.SDK_INT >= 24) {
                row(ctx, it, "HDR",       display?.hdrCapabilities?.supportedHdrTypes?.joinToString(",") ?: "—")
            }
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                row(ctx, it, "Wide gamut", display?.isWideColorGamut?.toString() ?: "—")
            }
            val cfg = resources.configuration
            val dark = (cfg.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES
            row(ctx, it, "Dark mode", dark.toString())
            row(ctx, it, "Font scale", "${cfg.fontScale}x")
        }

        // ── APK provenance ─────────────────────────────────────────────
        section(ctx, column, "APK provenance") {
            val pm = packageManager
            val pkg = packageName
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                val src = runCatching { pm.getInstallSourceInfo(pkg) }.getOrNull()
                row(ctx, it, "Installed by", src?.installingPackageName ?: "—")
                row(ctx, it, "Initiated by", src?.initiatingPackageName ?: "—")
                if (android.os.Build.VERSION.SDK_INT >= 33)
                    row(ctx, it, "Update owner", src?.updateOwnerPackageName ?: "—")
            } else {
                @Suppress("DEPRECATION")
                val installer = runCatching { pm.getInstallerPackageName(pkg) }.getOrNull()
                row(ctx, it, "Installed by", installer ?: "—")
            }
            // Signing cert SHA-256 — proves "this APK was signed by my keystore"
            val sigInfo = runCatching {
                if (android.os.Build.VERSION.SDK_INT >= 28) {
                    pm.getPackageInfo(pkg, android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
                } else null
            }.getOrNull()
            val sigs = sigInfo?.signingCertificateHistory ?: sigInfo?.apkContentsSigners
            if (sigs.isNullOrEmpty()) {
                row(ctx, it, "Cert SHA-256", "—")
            } else {
                val md = java.security.MessageDigest.getInstance("SHA-256")
                val hex = md.digest(sigs[0].toByteArray()).joinToString(":") { "%02X".format(it) }
                row(ctx, it, "Cert SHA-256", hex)
            }
            // Split APKs (base + per-density + per-ABI).
            // PackageInfo.applicationInfo is @Nullable as of API 35;
            // safe-call every access and degrade to "—" / 0 if the
            // platform decides not to hand us an ApplicationInfo.
            @Suppress("DEPRECATION")
            val appInfo = pm.getPackageInfo(pkg, 0).applicationInfo
            val splits = appInfo?.splitSourceDirs?.size ?: 0
            row(ctx, it, "Splits",      "$splits split APK(s)")
            row(ctx, it, "Native lib dir", appInfo?.nativeLibraryDir ?: "—")
            val nativeLibs = runCatching { File(appInfo?.nativeLibraryDir ?: "").listFiles()?.map { it.name } }.getOrNull()
            row(ctx, it, "Native libs", nativeLibs?.joinToString(", ") ?: "—")
        }

        // ── Sensors ────────────────────────────────────────────────────
        section(ctx, column, "Sensors") {
            val sm = getSystemService(Context.SENSOR_SERVICE) as? android.hardware.SensorManager
            val all = sm?.getSensorList(android.hardware.Sensor.TYPE_ALL) ?: emptyList()
            row(ctx, it, "Count", all.size.toString())
            for ((idx, s) in all.withIndex()) {
                row(ctx, it, "Sensor ${idx + 1}", "${s.name} — ${s.vendor}")
            }
        }

        // ── Security posture ───────────────────────────────────────────
        section(ctx, column, "Security posture") {
            val cr = contentResolver
            val devMode = runCatching {
                android.provider.Settings.Global.getInt(cr,
                    android.provider.Settings.Global.DEVELOPMENT_SETTINGS_ENABLED) == 1
            }.getOrDefault(false)
            val adbEnabled = runCatching {
                android.provider.Settings.Global.getInt(cr,
                    android.provider.Settings.Global.ADB_ENABLED) == 1
            }.getOrDefault(false)
            row(ctx, it, "Dev options", devMode.toString())
            row(ctx, it, "USB ADB",     adbEnabled.toString())
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                val adbWifi = runCatching {
                    android.provider.Settings.Global.getInt(cr, "adb_wifi_enabled") == 1
                }.getOrDefault(false)
                row(ctx, it, "Wireless ADB", adbWifi.toString())
            }
            val km = getSystemService(Context.KEYGUARD_SERVICE) as? android.app.KeyguardManager
            row(ctx, it, "Device secure",  (km?.isDeviceSecure ?: false).toString())
            row(ctx, it, "Keyguard locked", (km?.isKeyguardLocked ?: false).toString())
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                val bm = getSystemService(Context.BIOMETRIC_SERVICE)
                    as? android.hardware.biometrics.BiometricManager
                val biometric = runCatching {
                    @Suppress("DEPRECATION")
                    bm?.canAuthenticate() ?: -1
                }.getOrDefault(-1)
                row(ctx, it, "Biometric ready", when (biometric) {
                    android.hardware.biometrics.BiometricManager.BIOMETRIC_SUCCESS              -> "Yes"
                    android.hardware.biometrics.BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED  -> "No (not enrolled)"
                    android.hardware.biometrics.BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE    -> "No (no hardware)"
                    android.hardware.biometrics.BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "Hardware unavailable"
                    else -> "Unknown"
                })
            }
        }

        // ── Stack ──────────────────────────────────────────────────────
        section(ctx, column, "Stack") {
            it.addView(small(ctx, "What's actually inside this APK — scanned by the build, never a hardcoded list."))
            val langs = runCatching {
                JSONObject(String(Base64.decode(BuildConfig.STACK_LANGUAGES_JSON_B64, Base64.DEFAULT)))
            }.getOrDefault(JSONObject())
            var totalFiles = 0; var totalLoc = 0
            val langList = mutableListOf<Triple<String, Int, Int>>()
            val keys = langs.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val o = langs.optJSONObject(k) ?: continue
                val files = o.optInt("files"); val loc = o.optInt("loc")
                totalFiles += files; totalLoc += loc
                langList += Triple(k, files, loc)
            }
            row(ctx, it, "Total LOC",   "%,d lines".format(totalLoc))
            row(ctx, it, "Total files", totalFiles.toString())
            for ((lang, files, loc) in langList.sortedByDescending { tr -> tr.third }) {
                val pct = if (totalLoc > 0) " (%d%%)".format(loc * 100 / totalLoc) else ""
                row(ctx, it, lang, "%,d lines · %d file(s)%s".format(loc, files, pct))
            }

            it.addView(small(ctx, "Frameworks (Maven coordinates scanned from every *.gradle):"))
            val fw = runCatching {
                JSONArray(String(Base64.decode(BuildConfig.STACK_FRAMEWORKS_JSON_B64, Base64.DEFAULT)))
            }.getOrDefault(JSONArray())
            row(ctx, it, "Dep count", fw.length().toString())
            for (i in 0 until fw.length()) {
                val dep = fw.getString(i)
                val parts = dep.split(":")
                val head = if (parts.size >= 2) "${parts[0]}:${parts[1]}" else dep
                val ver  = if (parts.size >= 3) parts[2] else "?"
                row(ctx, it, head, ver)
            }

            it.addView(small(ctx, "Build metrics (from GitHub Actions history):"))
            row(ctx, it, "Build avg time", fmtSecs(BuildConfig.STACK_BUILD_AVG_SECS) +
                if (BuildConfig.STACK_BUILD_SAMPLE > 0) " (n=${BuildConfig.STACK_BUILD_SAMPLE})" else "")
            row(ctx, it, "Build last",     fmtSecs(BuildConfig.STACK_BUILD_LAST_SECS))
            row(ctx, it, "Build SHA",      BuildConfig.GIT_SHORT_SHA)
        }

        // ── Locale & time ──────────────────────────────────────────────
        section(ctx, column, "Locale & time") {
            val locales = if (android.os.Build.VERSION.SDK_INT >= 24)
                (0 until resources.configuration.locales.size()).joinToString(", ") {
                    resources.configuration.locales[it].toLanguageTag()
                }
            else
                @Suppress("DEPRECATION") resources.configuration.locale.toLanguageTag()
            row(ctx, it, "Locales",  locales)
            val tz = TimeZone.getDefault()
            row(ctx, it, "Timezone", "${tz.id} (${tz.displayName})")
            val offMin = tz.rawOffset / 60000
            row(ctx, it, "UTC offset", "%+03d:%02d".format(offMin / 60, kotlin.math.abs(offMin) % 60))
            row(ctx, it, "In DST",   tz.inDaylightTime(Date()).toString())
            val autoTime = runCatching {
                android.provider.Settings.Global.getInt(contentResolver,
                    android.provider.Settings.Global.AUTO_TIME) == 1
            }.getOrDefault(false)
            row(ctx, it, "Auto time", autoTime.toString())
            // System uptime gap = boot wall-clock.
            val bootWall = System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime()
            row(ctx, it, "Booted",   fmtMillis(bootWall))
            row(ctx, it, "System uptime", fmtDuration(android.os.SystemClock.elapsedRealtime()))
        }

        // ── Updates ────────────────────────────────────────────────────
        section(ctx, column, "Updates") {
            updateProgress = ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal).apply {
                max = 100; visibility = View.GONE
            }
            it.addView(updateProgress)
            updateStatus = TextView(ctx).apply {
                setTextColor(0xCCFFFFFF.toInt())
                setTextAppearance(android.R.style.TextAppearance_Material_Caption)
                setPadding(0, dp(6), 0, dp(8))
            }
            it.addView(updateStatus)
            it.addView(actionButton(ctx, getString(R.string.about_check_updates)) {
                FleetUpdater.checkNow(ctx)
                updateStatus.text = getString(R.string.about_update_started)
            })
        }

        // ── Copy All Infos (tail anchor) ───────────────────────────────
        column.addView(actionButton(ctx, "Copy All Infos") {
            val snapshot = infoBuf.toString()
            copy(ctx, snapshot)
            Toast.makeText(ctx,
                "Copied ${snapshot.length} chars (${snapshot.count { c -> c == '\n' }} lines)",
                Toast.LENGTH_SHORT).show()
        })

        setContentView(scroll)
    }

    override fun onResume() {
        super.onResume()
        UpdateProgress.setListener { s -> runOnUiThread { renderProgress(s) } }
    }

    override fun onPause() {
        super.onPause()
        UpdateProgress.setListener(null)
    }

    private fun renderProgress(s: UpdateProgress.State) {
        if (!::updateProgress.isInitialized) return
        when (s) {
            is UpdateProgress.State.Idle -> {
                updateProgress.visibility = View.GONE; updateStatus.text = ""
            }
            is UpdateProgress.State.Checking -> {
                updateProgress.visibility = View.VISIBLE; updateProgress.isIndeterminate = true
                updateStatus.text = "Checking ${s.target}…"
            }
            is UpdateProgress.State.Downloading -> {
                updateProgress.visibility = View.VISIBLE; updateProgress.isIndeterminate = false
                updateProgress.progress = s.percent
                updateStatus.text = "Downloading ${s.target}: ${s.percent}%"
            }
            is UpdateProgress.State.Installing -> {
                updateProgress.visibility = View.VISIBLE; updateProgress.isIndeterminate = true
                updateStatus.text = "Installing ${s.target}…"
            }
            is UpdateProgress.State.UpToDate -> {
                updateProgress.visibility = View.GONE
                updateStatus.text = "Checked ${s.checked} app(s) — fleet up to date."
            }
            is UpdateProgress.State.Failed -> {
                updateProgress.visibility = View.GONE
                updateStatus.text = "Failed (${s.target}): ${s.message}"
            }
        }
    }

    // ── helpers (ported from DevControlFragment) ───────────────────────

    private fun section(ctx: Context, host: LinearLayout, head: String, body: (LinearLayout) -> Unit) {
        infoBuf.append("\n## ").append(head).append("\n")
        host.addView(sectionHeader(ctx, head))
        val grp = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, dp(8))
        }
        host.addView(grp)
        body(grp)
    }

    private fun row(ctx: Context, host: LinearLayout, key: String, value: String): TextView {
        infoBuf.append("  ").append(key).append(": ").append(value).append("\n")
        val rowView = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(4), 0, dp(4))
        }
        rowView.addView(TextView(ctx).apply {
            text = key
            setTextColor(0xCCFFFFFF.toInt())
            setTextAppearance(android.R.style.TextAppearance_Material_Caption)
            layoutParams = LinearLayout.LayoutParams(dp(120), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        val valueView = TextView(ctx).apply {
            text = value
            setTextColor(0xFFB794F4.toInt())
            typeface = Typeface.MONOSPACE
            setTextAppearance(android.R.style.TextAppearance_Material_Caption)
            setTextIsSelectable(true)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnLongClickListener {
                copy(ctx, "$key: $value")
                Toast.makeText(ctx, "Copied $key", Toast.LENGTH_SHORT).show(); true
            }
        }
        rowView.addView(valueView)
        host.addView(rowView)
        return valueView
    }

    private fun title(ctx: Context, text: String) = TextView(ctx).apply {
        infoBuf.append("# ").append(text).append("\n")
        this.text = text
        setTextColor(0xFFE9D8FD.toInt())
        typeface = Typeface.DEFAULT_BOLD
        setTextAppearance(android.R.style.TextAppearance_Material_Headline)
        setPadding(0, 0, 0, dp(12))
    }

    private fun sectionHeader(ctx: Context, text: String) = TextView(ctx).apply {
        this.text = text
        setTextColor(0xFF7C3AED.toInt())
        typeface = Typeface.DEFAULT_BOLD
        setTextAppearance(android.R.style.TextAppearance_Material_Subhead)
        setPadding(0, dp(14), 0, dp(4))
    }

    private fun small(ctx: Context, text: String) = TextView(ctx).apply {
        infoBuf.append("  ").append(text).append("\n")
        this.text = text
        setTextColor(0x99FFFFFF.toInt())
        setTextAppearance(android.R.style.TextAppearance_Material_Caption)
        setPadding(0, dp(4), 0, dp(4))
    }

    private fun actionButton(ctx: Context, label: String, onClick: () -> Unit) = TextView(ctx).apply {
        text = label
        setTextColor(0xFFFFFFFF.toInt())
        setBackgroundColor(0xFF7C3AED.toInt())
        gravity = android.view.Gravity.CENTER
        setPadding(dp(12), dp(10), dp(12), dp(10))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(8) }
        isClickable = true; isFocusable = true
        setOnClickListener { onClick() }
    }

    private fun copy(ctx: Context, v: String) {
        val clip = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clip?.setPrimaryClip(ClipData.newPlainText("about", v))
    }

    private fun permissionState(perm: String): String {
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(this, perm) ==
            PackageManager.PERMISSION_GRANTED
        return if (granted) "✓ Granted" else "✗ Denied"
    }

    private fun openAppSettings() {
        runCatching {
            startActivity(android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", packageName, null),
            ))
        }
    }

    private fun fmtMillis(ms: Long): String =
        DateFormat.getDateTimeInstance().format(Date(ms))

    /** Recursive on-disk size of a directory — same helper superapp's Storage
     *  section uses for the Datos/Caché breakdown. */
    private fun dirSize(dir: java.io.File): Long = runCatching {
        if (!dir.exists()) return@runCatching 0L
        dir.walkTopDown().filter { f -> f.isFile }.sumOf { f -> f.length() }
    }.getOrDefault(0L)

    private fun fmtSecs(s: Long): String = when {
        s < 0    -> "—"
        s < 60   -> "${s}s"
        s < 3600 -> "%dm %02ds".format(s / 60, s % 60)
        else     -> "%dh %02dm".format(s / 3600, (s % 3600) / 60)
    }

    /** h/min/s duration formatter — same helper superapp's Battery & Usage
     *  / Battery (deep) / Locale & time sections use. */
    private fun fmtDuration(ms: Long): String {
        if (ms < 0) return "—"
        val s = ms / 1000
        val h = s / 3600
        val m = (s % 3600) / 60
        val sec = s % 60
        return when {
            h > 0 -> "%d h %02d min".format(h, m)
            m > 0 -> "%d min %02d s".format(m, sec)
            else  -> "%d s".format(sec)
        }
    }

    /** (free, total) bytes for the filesystem hosting [path]. Returns
     *  (-1, -1) when StatFs throws — happens on early-API or unmounted
     *  external paths. */
    private fun statFsBytes(path: String): Pair<Long, Long> = runCatching {
        val s = android.os.StatFs(path)
        s.availableBytes to s.totalBytes
    }.getOrDefault(-1L to -1L)

    /** (swapTotalBytes, swapFreeBytes) from /proc/meminfo. -1L on parse
     *  failure; 0L SwapTotal means the kernel has no swap configured
     *  (caller should render "disabled"). Values in /proc/meminfo are
     *  in kB — multiplied to bytes here so callers stay in sizeStr units. */
    private fun readSwapBytes(): Pair<Long, Long> = runCatching {
        val text = File("/proc/meminfo").readText()
        fun kb(field: String): Long {
            val m = Regex("(?m)^${field}:\\s+(\\d+)\\s+kB").find(text)
                ?: return -1L
            return m.groupValues[1].toLong() * 1024L
        }
        kb("SwapTotal") to kb("SwapFree")
    }.getOrDefault(-1L to -1L)

    private fun sizeStr(bytes: Long): String = when {
        bytes >= 1_073_741_824 -> "%.2f GiB".format(bytes / 1_073_741_824.0)
        bytes >= 1_048_576     -> "%.2f MiB".format(bytes / 1_048_576.0)
        bytes >= 1024          -> "%.1f KiB".format(bytes / 1024.0)
        else                   -> "$bytes B"
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        /** Intent extra mirroring superapp's shortcut grammar. MainActivity
         *  dispatches `action:check_updates` → checkNow + open this Activity. */
        const val EXTRA_SHORTCUT_ACTION = "shortcut_action"
    }
}
