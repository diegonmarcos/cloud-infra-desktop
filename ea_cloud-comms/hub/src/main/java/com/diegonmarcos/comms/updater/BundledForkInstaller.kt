package com.diegonmarcos.comms.updater

import android.content.Context
import android.util.Log
import java.io.File

/**
 * The "all together in one download" half of the embedded-installer model.
 *
 * The single Cloud-Comms hub APK physically carries each fork APK inside it
 * (assets/forks/<domain>.apk, seeded at build time by `build.sh bundle-forks`).
 * On first launch — or when the user taps an uninstalled fork tile — the hub
 * copies the bundled APK out of assets and installs it via PackageInstaller
 * (UpdateInstaller). No network needed for first setup; the FleetUpdater then
 * keeps each fork current from GHCR.
 *
 * Android's no-root security model still shows one install-confirmation dialog
 * per fork; this just removes the need to find/download three separate files.
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

    /**
     * Install the bundled fork for [domain]. Copies the asset to cacheDir and
     * hands it to PackageInstaller (user confirms). Returns false if there's no
     * bundled APK for that domain or the fork's app id is unknown.
     */
    fun install(ctx: Context, domain: String): Boolean {
        val appId = FleetUpdater.fleet.firstOrNull { it.label == domain }?.appId ?: return false
        if (!hasBundle(ctx, domain)) {
            Log.i(TAG, "$domain: no bundled APK (not published/bundled yet)"); return false
        }
        val out = File(ctx.cacheDir, "bundled-$domain.apk")
        ctx.assets.open("$ASSET_DIR/$domain.apk").use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        Log.i(TAG, "$domain: installing bundled APK → $appId")
        UpdateInstaller(ctx).install(out, appId)
        return true
    }

    /** First-run convenience: install every bundled fork that isn't already
        installed and isn't blocked. Returns how many installs were kicked off. */
    fun installMissing(ctx: Context): Int {
        var started = 0
        for (entry in FleetUpdater.fleet) {
            if (entry.label == "hub" || entry.blocked) continue
            if (entry.isInstalled(ctx)) continue
            if (install(ctx, entry.label)) started++
        }
        return started
    }
}
