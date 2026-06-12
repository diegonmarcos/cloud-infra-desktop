package com.diegonmarcos.comms

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject

/**
 * The permanent "wrapper chrome" top bar that makes the constellation feel like
 * ONE owned product. Inside ANY app you own, it lets you jump to every OTHER
 * one: Cloud-SuperApp · Cloud-Comms · {the other comms apps}.
 *
 * The node list is data-driven from TWO baked sources (no hardcoded list):
 *   • data/constellation-chrome.json::chain → the non-fork ancestors
 *     (Cloud-SuperApp, Cloud-Comms)
 *   • build.json::forks → the comms apps (Mail / Mattermost / Element)
 * The bar renders a button for every node that is NOT the current app, so:
 *   • inside Mail   → [↑ Cloud-SuperApp][↑ Cloud-Comms][Mattermost][Element]
 *   • inside the hub → [↑ Cloud-SuperApp][Mail][Mattermost][Element]
 *
 * This is BOTH the hub's own bar AND the reference implementation each fork's
 * branding patch ports verbatim (the forks can't depend on this APK's code; the
 * patch ships the same JSON in the fork's assets).
 */
object ConstellationBar {

    data class Node(val label: String, val pkg: String, val altPkg: String?, val isFork: Boolean)

    /** Full constellation, ancestors first then comms apps. altPkg = the stock
     *  upstream APK's real package, accepted until the patched fork ships. */
    fun nodes(): List<Node> {
        val out = ArrayList<Node>()
        val chrome = JSONObject(String(Base64.decode(BuildConfig.CHROME_JSON_B64, Base64.DEFAULT)))
        val chain = chrome.getJSONArray("chain")
        for (i in 0 until chain.length()) {
            val o = chain.getJSONObject(i)
            out += Node(o.getString("label"), o.getString("package"), null, isFork = false)
        }
        val forks = JSONObject(String(Base64.decode(BuildConfig.FORKS_JSON_B64, Base64.DEFAULT)))
        for (domain in forks.keys()) {
            val f = forks.getJSONObject(domain)
            val label = f.optString("label").ifEmpty { domain.replaceFirstChar { it.uppercase() } }
            val alt = f.optJSONObject("upstream_apk")?.optString("package")?.takeIf { it.isNotEmpty() }
            out += Node(label, f.getString("app_id"), alt, isFork = true)
        }
        return out
    }

    /** Build the bar for [selfPackage]. Renders the FULL constellation —
     *  Cloud-SuperApp | Cloud-Comms • Mail | Mattermost | Element — with the
     *  current app highlighted (the user always sees where they are; the other
     *  entries navigate). Null only if the constellation is empty. */
    fun build(ctx: Context, selfPackage: String): View? {
        val all = nodes()
        if (all.isEmpty()) return null
        val chrome = JSONObject(String(Base64.decode(BuildConfig.CHROME_JSON_B64, Base64.DEFAULT)))
        val bar = chrome.getJSONObject("top_bar")
        val glyph = bar.optString("back_glyph", "↑")
        val heightDp = bar.optInt("height_dp", 44)
        val density = ctx.resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(4), 0)
        }
        for (n in all) {
            val isSelf = n.pkg == selfPackage
            // Ancestors get the back-glyph; comms apps get a dot; the current
            // app gets no prefix — it's highlighted instead.
            val prefix = when {
                isSelf -> ""
                n.isFork -> "• "
                else -> "$glyph "
            }
            row.addView(TextView(ctx).apply {
                text = "$prefix${n.label}"
                textSize = 13f
                setPadding(dp(12), dp(8), dp(12), dp(8))
                if (isSelf) {
                    // Current app: bold + underline-style accent, not a button.
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setBackgroundColor(Color.parseColor("#337C3AED"))
                } else {
                    isClickable = true
                    setOnClickListener { open(ctx, n) }
                }
            })
        }
        return HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(Color.parseColor("#11000000"))
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(heightDp))
            addView(row)
        }
    }

    /** Open a node. Forks are launcher-icon-less → opened by the declared
        signature-gated action; ancestors keep their icon → launcher intent.
        Try action first, fall back to launcher, else toast. */
    private fun open(ctx: Context, n: Node) {
        if (n.isFork) {
            val byAction = Intent(CommsContract.LAUNCH_ACTION)
                .setPackage(n.pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (byAction.resolveActivity(ctx.packageManager) != null) {
                ctx.startActivity(byAction); return
            }
        }
        for (id in listOfNotNull(n.pkg, n.altPkg)) {
            val launch = ctx.packageManager.getLaunchIntentForPackage(id)
            if (launch != null) {
                ctx.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return
            }
        }
        Toast.makeText(ctx, "${n.label} is not installed", Toast.LENGTH_SHORT).show()
    }
}
