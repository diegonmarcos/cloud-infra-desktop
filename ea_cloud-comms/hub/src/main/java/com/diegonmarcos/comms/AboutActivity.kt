package com.diegonmarcos.comms

import android.os.Bundle
import android.util.Base64
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.diegonmarcos.comms.updater.BundledForkInstaller
import com.diegonmarcos.comms.updater.FleetUpdater
import com.diegonmarcos.comms.updater.UpdateProgress
import org.json.JSONArray
import org.json.JSONObject

/**
 * Configs → About — the SAME flavour of "full of info" as Cloud-SuperApp's
 * About: app identity, build timing history, the IPC contract, the live
 * constellation (per app: installed version / license / runtime / pinned tag /
 * bundled? / blocked), a config-time stack scan (languages + dependencies +
 * build time), and a one-tap fleet updater with a live progress bar. Everything
 * is read from BuildConfig (baked from build.json / contract / chrome at build
 * time) + runtime PackageManager — no hardcoded facts.
 */
class AboutActivity : AppCompatActivity() {

    private lateinit var status: TextView
    private lateinit var progress: ProgressBar

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = getString(R.string.about_title)

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(28))
        }

        // Header: icon + title
        col.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ImageView(this@AboutActivity).apply {
                setImageResource(R.drawable.ic_comms)
                layoutParams = LinearLayout.LayoutParams(dp(40), dp(40))
            })
            addView(TextView(this@AboutActivity).apply {
                text = "  ${getString(R.string.app_name)}"
                textSize = 22f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
        })

        section(col, "🏗", getString(R.string.about_sec_build))
        body(col,
            "version    ${BuildConfig.VERSION_NAME}\n" +
            "code       ${BuildConfig.VERSION_CODE}\n" +
            "sha        ${BuildConfig.GIT_SHORT_SHA}\n" +
            "built      ${BuildConfig.BUILD_TIMESTAMP}\n" +
            "build time last ${fmtSecs(BuildConfig.STACK_BUILD_LAST_SECS)} · " +
            "avg ${fmtSecs(BuildConfig.STACK_BUILD_AVG_SECS)} (${BuildConfig.STACK_BUILD_SAMPLE})")

        section(col, "🔌", getString(R.string.about_sec_ipc))
        body(col,
            "contract   v${BuildConfig.IPC_VERSION}\n" +
            "authority  ${BuildConfig.IPC_AUTHORITY}\n" +
            "permission ${BuildConfig.IPC_PERMISSION}\n" +
            "open       ${BuildConfig.LAUNCH_ACTION}\n" +
            "signature-gated · all constellation APKs share one key")

        section(col, "🌌", getString(R.string.about_sec_fleet))
        body(col, fleetReport())

        section(col, "📦", getString(R.string.about_sec_stack))
        body(col, stackReport())

        section(col, "🔄", getString(R.string.about_sec_updates))
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100; visibility = android.view.View.GONE
        }
        col.addView(progress)
        status = TextView(this).apply { textSize = 13f; setPadding(0, dp(6), 0, dp(8)) }
        col.addView(Button(this).apply {
            text = getString(R.string.about_check_updates)
            setOnClickListener {
                FleetUpdater.checkNow(this@AboutActivity)
                status.text = getString(R.string.about_update_started)
            }
        })
        col.addView(status)

        setContentView(ScrollView(this).apply { addView(col, ViewGroup.LayoutParams(MATCH, WRAP)) })
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
        when (s) {
            is UpdateProgress.State.Idle -> { progress.visibility = android.view.View.GONE; status.text = "" }
            is UpdateProgress.State.Checking -> {
                progress.visibility = android.view.View.VISIBLE; progress.isIndeterminate = true
                status.text = "Checking ${s.target}…"
            }
            is UpdateProgress.State.Downloading -> {
                progress.visibility = android.view.View.VISIBLE; progress.isIndeterminate = false
                progress.progress = s.percent
                status.text = "Downloading ${s.target}: ${s.percent}%"
            }
            is UpdateProgress.State.Installing -> {
                progress.visibility = android.view.View.VISIBLE; progress.isIndeterminate = true
                status.text = "Installing ${s.target}…"
            }
            is UpdateProgress.State.UpToDate -> {
                progress.visibility = android.view.View.GONE
                status.text = "Checked ${s.checked} app(s) — fleet up to date."
            }
            is UpdateProgress.State.Failed -> {
                progress.visibility = android.view.View.GONE
                status.text = "Failed (${s.target}): ${s.message}"
            }
        }
    }

    /** Per-app constellation status, merging the baked fork registry + fleet +
        live PackageManager + bundled-asset presence. */
    private fun fleetReport(): String {
        val forks = JSONObject(String(Base64.decode(BuildConfig.FORKS_JSON_B64, Base64.DEFAULT)))
        val sb = StringBuilder()
        for (e in FleetUpdater.fleet) {
            val installed = e.installedVersion(this)
            val state = when {
                e.blocked -> "blocked"
                installed != null -> "v$installed"
                BundledForkInstaller.hasBundle(this, e.label) -> "bundled · tap to install"
                else -> "not bundled yet"
            }
            val name = if (e.label == "hub") "Cloud-Comms (hub)"
                       else forks.optJSONObject(e.label)?.optString("label") ?: e.label
            sb.append("• ${name}\n    $state\n")
            if (e.label != "hub") forks.optJSONObject(e.label)?.let { f ->
                val pin = f.optString("pinned_tag").ifEmpty { "—" }
                sb.append("    ${f.optString("license")} · ${f.optString("runtime")} · pin $pin\n")
            } else sb.append("    image ${e.image}\n")
        }
        return sb.toString().trimEnd()
    }

    private fun stackReport(): String {
        val langs = JSONObject(String(Base64.decode(BuildConfig.STACK_LANGUAGES_JSON_B64, Base64.DEFAULT)))
        var totalFiles = 0; var totalLoc = 0
        val sb = StringBuilder("languages:\n")
        for (k in langs.keys()) {
            val o = langs.getJSONObject(k)
            totalFiles += o.optInt("files"); totalLoc += o.optInt("loc")
            sb.append("  ${k}: ${o.optInt("files")} files, ${o.optInt("loc")} loc\n")
        }
        sb.append("  total: $totalFiles files, $totalLoc loc\n")
        val fw = JSONArray(String(Base64.decode(BuildConfig.STACK_FRAMEWORKS_JSON_B64, Base64.DEFAULT)))
        sb.append("dependencies (${fw.length()}):\n")
        for (i in 0 until fw.length()) sb.append("  ${fw.getString(i)}\n")
        return sb.toString().trimEnd()
    }

    private fun fmtSecs(s: Long): String =
        if (s < 0) "—" else if (s < 60) "${s}s" else "${s / 60}m ${s % 60}s"

    private fun section(parent: LinearLayout, glyph: String, t: String) {
        parent.addView(TextView(this).apply {
            text = "$glyph  $t"
            textSize = 16f
            setPadding(0, dp(20), 0, dp(6))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
    }

    private fun body(parent: LinearLayout, t: String) {
        parent.addView(TextView(this).apply {
            text = t
            textSize = 13f
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        })
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    }
}
