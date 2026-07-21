package com.diegonmarcos.comms

import android.content.Context
import android.content.pm.PackageManager
import android.util.Base64
import org.json.JSONObject

/**
 * The set of forks the hub knows about, read from `build.json::forks` baked into
 * BuildConfig.FORKS_JSON_B64 — NO hardcoded list (FIRE rule 6). Each entry maps a
 * domain ("mail"/"chat"/"matrix") to the fork's applicationId, tracker dir and
 * blocked state, plus a runtime check of whether that APK is installed.
 */
data class Fork(
    val domain: String,
    val label: String,
    val appId: String,
    /** Real package of the STOCK upstream APK bundled until the patched fork
     *  (which carries [appId]) replaces it — detection/launch accept either. */
    val altId: String?,
    val trackerDir: String,
    val license: String,
    val runtime: String,
    val priority: Int,
    val blockedOn: String?,
) {
    fun installedId(ctx: Context): String? {
        for (id in listOfNotNull(appId, altId)) {
            try { ctx.packageManager.getPackageInfo(id, 0); return id }
            catch (e: PackageManager.NameNotFoundException) { /* next */ }
        }
        return null
    }

    fun isInstalled(ctx: Context): Boolean = installedId(ctx) != null
}

object ForkRegistry {
    val forks: List<Fork> by lazy { parse() }

    fun byDomain(domain: String): Fork? = forks.firstOrNull { it.domain == domain }

    private fun parse(): List<Fork> {
        val json = String(Base64.decode(BuildConfig.FORKS_JSON_B64, Base64.DEFAULT))
        val root = JSONObject(json)
        return root.keys().asSequence().map { domain ->
            val o = root.getJSONObject(domain)
            Fork(
                domain = domain,
                label = o.optString("label").ifEmpty { domain.replaceFirstChar { c -> c.uppercase() } },
                appId = o.optString("app_id"),
                altId = o.optJSONObject("upstream_apk")?.optString("package")?.takeIf { it.isNotEmpty() },
                trackerDir = o.optString("tracker_dir"),
                license = o.optString("license"),
                runtime = o.optString("runtime"),
                priority = o.optInt("priority", 99),
                // RUNTIME blocked ≠ fork-build blocked: blocked_on gates building
                // OUR patched fork, not installing the bundled stock client. If
                // an upstream_apk is bundled (installable), the tile is NOT
                // blocked. Matches the fleet's blocked computation in build.gradle.
                blockedOn = o.optString("blocked_on")
                    .takeIf { it.isNotEmpty() && it != "null" }
                    ?.takeIf { o.optJSONObject("upstream_apk")?.optString("url").isNullOrEmpty() },
            )
        }.sortedBy { it.priority }.toList()
    }
}
