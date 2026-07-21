package com.diegonmarcos.comms.updater

import android.content.Context
import android.util.Log
import java.io.File

/**
 * The "all together in one download" half of the embedded-installer model.
 *
 * The single Cloud-Comms hub APK physically carries each fork APK inside it
 * (assets/forks/<domain>.apk, seeded at build time by `build.sh bundle-forks`).
 * This is the asset-extraction helper used by [Transaction]'s FETCH phase —
 * a bundled fork needs no network for first setup; the periodic transaction
 * then keeps each fork current from GHCR. Bundled APKs are trusted (they
 * shipped inside our signed APK), so the VERIFY phase skips them.
 */
object BundledForkInstaller {
    private const val TAG = "Updater/Bundle"
    private const val ASSET_DIR = "forks"

    /** Domains that actually have an embedded APK in this build (empty until the
        forks are published + bundled). */
    fun bundledDomains(ctx: Context): List<String> =
        (ctx.assets.list(ASSET_DIR) ?: emptyArray())
            .filter { it.endsWith(".apk") }
            .map { it.removeSuffix(".apk") }

    fun hasBundle(ctx: Context, domain: String): Boolean =
        bundledDomains(ctx).contains(domain)

    /** Copy the bundled APK for [domain] out of assets into [out]. Returns
     *  false when this build carries no bundle for that domain. */
    fun extractTo(ctx: Context, domain: String, out: File): Boolean {
        if (!hasBundle(ctx, domain)) {
            Log.i(TAG, "$domain: no bundled APK (not published/bundled yet)")
            return false
        }
        ctx.assets.open("$ASSET_DIR/$domain.apk").use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        Log.i(TAG, "$domain: extracted bundled APK → ${out.name} (${out.length()} bytes)")
        return true
    }
}
