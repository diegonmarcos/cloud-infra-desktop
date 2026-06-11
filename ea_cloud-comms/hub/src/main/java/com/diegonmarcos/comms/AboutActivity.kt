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
import java.text.DateFormat
import java.util.Date

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

        // ── Memory ─────────────────────────────────────────────────────
        section(ctx, column, "Memory") {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            val mi = android.app.ActivityManager.MemoryInfo()
            am?.getMemoryInfo(mi)
            row(ctx, it, "System avail",      sizeStr(mi.availMem))
            row(ctx, it, "System total",      sizeStr(mi.totalMem))
            row(ctx, it, "Threshold",         sizeStr(mi.threshold))
            row(ctx, it, "System low-memory", mi.lowMemory.toString())
            row(ctx, it, "Heap class limit",  am?.memoryClass?.let { c -> "$c MB" } ?: "—")
            row(ctx, it, "Heap class (large)", am?.largeMemoryClass?.let { c -> "$c MB" } ?: "—")
            val rt = Runtime.getRuntime()
            row(ctx, it, "JVM heap used",
                "${sizeStr(rt.totalMemory() - rt.freeMemory())} / ${sizeStr(rt.maxMemory())}")
        }

        // ── Permissions ────────────────────────────────────────────────
        section(ctx, column, "Permissions") {
            it.addView(small(ctx, "Manifest permissions — States: ✓ Granted · ✗ Denied. Normal/signature perms are auto-granted at install; runtime perms (notifications on API 33+) need a prompt."))
            // The hub's ACTUAL manifest permissions (see AndroidManifest.xml).
            val perms = listOf(
                "INTERNET"                to "android.permission.INTERNET",
                "Network state"           to "android.permission.ACCESS_NETWORK_STATE",
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
