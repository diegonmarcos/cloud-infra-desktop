package com.diegonmarcos.comms

import android.content.Context
import android.content.Intent
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject

/**
 * The permanent "wrapper chrome" top bar that makes the constellation feel like
 * one owned product: Cloud-SuperApp ▸ Cloud-Comms ▸ {Mail,Mattermost,Element}.
 *
 * Data-driven from data/constellation-chrome.json (baked into BuildConfig). It
 * renders a back-button for every chain entry that is NOT the current app — so
 * the hub shows [↑ Cloud-SuperApp] and each fork shows
 * [↑ Cloud-SuperApp][↑ Cloud-Comms]. Tapping opens that ancestor app.
 *
 * This is BOTH the hub's own bar AND the reference implementation each fork's
 * branding patch reproduces (the forks can't share this APK's code, so the
 * patch ports this ~40-line builder verbatim, reading the same JSON shipped in
 * the fork's assets). Keeping one builder here keeps the bar pixel-consistent.
 */
object ConstellationBar {

    data class Ancestor(val label: String, val pkg: String)

    /** Chain entries above [selfPackage], in order (root first). */
    fun ancestorsFor(selfPackage: String): List<Ancestor> {
        val root = JSONObject(String(Base64.decode(BuildConfig.CHROME_JSON_B64, Base64.DEFAULT)))
        val chain = root.getJSONArray("chain")
        return (0 until chain.length()).map { chain.getJSONObject(it) }
            .map { Ancestor(it.getString("label"), it.getString("package")) }
            .filter { it.pkg != selfPackage }
    }

    /** Build the bar view for [selfPackage]. Returns null if there are no
        ancestors (e.g. the root app would render nothing). */
    fun build(ctx: Context, selfPackage: String): View? {
        val ancestors = ancestorsFor(selfPackage)
        if (ancestors.isEmpty()) return null
        val root = JSONObject(String(Base64.decode(BuildConfig.CHROME_JSON_B64, Base64.DEFAULT)))
        val bar = root.getJSONObject("top_bar")
        val glyph = bar.optString("back_glyph", "↑")
        val heightDp = bar.optInt("height_dp", 44)

        val density = ctx.resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(heightDp))
            for (a in ancestors) {
                addView(TextView(ctx).apply {
                    text = "$glyph ${a.label}"
                    textSize = 13f
                    setPadding(dp(12), dp(8), dp(12), dp(8))
                    isClickable = true
                    setOnClickListener { openAncestor(ctx, a) }
                })
            }
        }
    }

    private fun openAncestor(ctx: Context, a: Ancestor) {
        val launch = ctx.packageManager.getLaunchIntentForPackage(a.pkg)
        if (launch != null) {
            ctx.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } else {
            Toast.makeText(ctx, "${a.label} is not installed", Toast.LENGTH_SHORT).show()
        }
    }
}
