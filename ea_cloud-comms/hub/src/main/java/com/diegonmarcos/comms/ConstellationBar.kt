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

    data class Node(val label: String, val pkg: String, val isFork: Boolean)

    /** Full constellation, ancestors first then comms apps. */
    fun nodes(): List<Node> {
        val out = ArrayList<Node>()
        val chrome = JSONObject(String(Base64.decode(BuildConfig.CHROME_JSON_B64, Base64.DEFAULT)))
        val chain = chrome.getJSONArray("chain")
        for (i in 0 until chain.length()) {
            val o = chain.getJSONObject(i)
            out += Node(o.getString("label"), o.getString("package"), isFork = false)
        }
        val forks = JSONObject(String(Base64.decode(BuildConfig.FORKS_JSON_B64, Base64.DEFAULT)))
        for (domain in forks.keys()) {
            val f = forks.getJSONObject(domain)
            val label = f.optString("label").ifEmpty { domain.replaceFirstChar { it.uppercase() } }
            out += Node(label, f.getString("app_id"), isFork = true)
        }
        return out
    }

    /** Build the bar for [selfPackage]; null if there are no other apps. */
    fun build(ctx: Context, selfPackage: String): View? {
        val others = nodes().filter { it.pkg != selfPackage }
        if (others.isEmpty()) return null
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
        for (n in others) {
            // Ancestors get the back-glyph; sibling comms apps get a dot.
            val prefix = if (n.isFork) "•" else glyph
            row.addView(TextView(ctx).apply {
                text = "$prefix ${n.label}"
                textSize = 13f
                setPadding(dp(12), dp(8), dp(12), dp(8))
                isClickable = true
                setOnClickListener { open(ctx, n) }
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
        val launch = ctx.packageManager.getLaunchIntentForPackage(n.pkg)
        if (launch != null) {
            ctx.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } else {
            Toast.makeText(ctx, "${n.label} is not installed", Toast.LENGTH_SHORT).show()
        }
    }
}
