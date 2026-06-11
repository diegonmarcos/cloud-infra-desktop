package com.diegonmarcos.comms

import android.os.Bundle
import android.util.Base64
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.diegonmarcos.comms.updater.FleetUpdater
import com.diegonmarcos.comms.updater.UpdateProgress
import org.json.JSONArray
import org.json.JSONObject

/**
 * Configs → About. Renders the same flavour of "full of info" as the Cloud-
 * SuperApp About: build identity, the IPC contract, the live constellation
 * (each app's installed version / license / pinned tag / blocked state), the
 * baked stack scan, and a one-tap fleet update check. Everything here is read
 * from BuildConfig (baked from build.json / contract at build time) + runtime
 * PackageManager — no hardcoded facts.
 */
class AboutActivity : AppCompatActivity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = getString(R.string.about_title)

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(28))
        }

        section(col, getString(R.string.about_sec_build))
        body(col,
            "Cloud-Comms Hub ${BuildConfig.VERSION_NAME}\n" +
            "versionCode ${BuildConfig.VERSION_CODE} · sha ${BuildConfig.GIT_SHORT_SHA}\n" +
            "built ${BuildConfig.BUILD_TIMESTAMP}")

        section(col, getString(R.string.about_sec_ipc))
        body(col,
            "contract v${BuildConfig.IPC_VERSION}\n" +
            "authority  ${BuildConfig.IPC_AUTHORITY}\n" +
            "permission ${BuildConfig.IPC_PERMISSION}\n" +
            "signature-gated (all constellation APKs share one key)")

        section(col, getString(R.string.about_sec_fleet))
        body(col, fleetReport())

        section(col, getString(R.string.about_sec_stack))
        body(col, stackReport())

        status = TextView(this).apply { textSize = 13f; setPadding(0, dp(16), 0, dp(8)) }
        val checkBtn = Button(this).apply {
            text = getString(R.string.about_check_updates)
            setOnClickListener {
                FleetUpdater.checkNow(this@AboutActivity)
                status.text = getString(R.string.about_update_started)
            }
        }
        col.addView(checkBtn)
        col.addView(status)

        setContentView(ScrollView(this).apply {
            addView(col, ViewGroup.LayoutParams(MATCH, WRAP))
        })
    }

    override fun onResume() {
        super.onResume()
        UpdateProgress.setListener { s -> runOnUiThread { status.text = render(s) } }
    }

    override fun onPause() {
        super.onPause()
        UpdateProgress.setListener(null)
    }

    private fun render(s: UpdateProgress.State): String = when (s) {
        is UpdateProgress.State.Idle -> ""
        is UpdateProgress.State.Checking -> "Checking ${s.target}…"
        is UpdateProgress.State.Downloading -> "Downloading ${s.target}: ${s.percent}%"
        is UpdateProgress.State.Installing -> "Installing ${s.target}…"
        is UpdateProgress.State.UpToDate -> "Checked ${s.checked} app(s) — fleet up to date."
        is UpdateProgress.State.Failed -> "Failed (${s.target}): ${s.message}"
    }

    /** Per-app constellation status: installed version (or state) + license +
        pinned tag, merging the baked fork registry with live PackageManager. */
    private fun fleetReport(): String {
        val forks = JSONObject(String(Base64.decode(BuildConfig.FORKS_JSON_B64, Base64.DEFAULT)))
        val sb = StringBuilder()
        for (e in FleetUpdater.fleet) {
            val installed = e.installedVersion(this)
            val state = when {
                e.blocked -> "blocked"
                installed != null -> "v$installed"
                else -> "not installed"
            }
            sb.append("• ${e.label.padEnd(7)} $state\n")
            if (e.label != "hub" && forks.has(e.label)) {
                val f = forks.getJSONObject(e.label)
                val pin = f.optString("pinned_tag").ifEmpty { "—" }
                sb.append("    ${f.optString("license")} · ${f.optString("runtime")} · pin $pin\n")
            } else if (e.label == "hub") {
                sb.append("    image ${e.image}\n")
            }
        }
        return sb.toString().trimEnd()
    }

    private fun stackReport(): String {
        val langs = JSONObject(String(Base64.decode(BuildConfig.STACK_LANGUAGES_JSON_B64, Base64.DEFAULT)))
        val sb = StringBuilder("languages:\n")
        for (k in langs.keys()) {
            val o = langs.getJSONObject(k)
            sb.append("  ${k}: ${o.optInt("files")} files, ${o.optInt("loc")} loc\n")
        }
        val fw = JSONArray(String(Base64.decode(BuildConfig.STACK_FRAMEWORKS_JSON_B64, Base64.DEFAULT)))
        sb.append("dependencies (${fw.length()}):\n")
        for (i in 0 until fw.length()) sb.append("  ${fw.getString(i)}\n")
        return sb.toString().trimEnd()
    }

    private fun section(parent: LinearLayout, t: String) {
        parent.addView(TextView(this).apply {
            text = t; textSize = 16f; setPadding(0, dp(18), 0, dp(6)); gravity = Gravity.START
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
    }

    private fun body(parent: LinearLayout, t: String) {
        parent.addView(TextView(this).apply {
            text = t; textSize = 13f
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
