package com.diegonmarcos.comms.updater

import android.content.Context
import android.content.pm.PackageManager
import android.util.Base64
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.diegonmarcos.comms.BuildConfig
import org.json.JSONArray
import java.util.concurrent.TimeUnit

/** One updatable APK in the constellation. Parsed from BuildConfig
 *  (build.json: hub from release.ghcr + the three forks from forks.*). */
data class FleetEntry(
    val label: String,        // fleet KEY (hub|mail|chat|matrix|dialer) — used
                              // for asset names + logs, never shown to the user
    val displayName: String,  // user-facing name from build.json::forks.<k>.label
                              // ("Mail (FairEmail)", "Chat (Mattermost)", …)
    val appId: String,     // OUR id (the patched fork's applicationId)
    val altId: String?,    // the STOCK upstream APK's real package (until the
                           // patched fork replaces it) — installed-detection
                           // and launching accept either id
    val image: String,     // GHCR image name
    val blocked: Boolean,  // fork blocked_on set → never check
) {
    /** Whichever of the two ids is actually on the device, or null. */
    fun installedId(ctx: Context): String? {
        for (id in listOfNotNull(appId, altId)) {
            try { ctx.packageManager.getPackageInfo(id, 0); return id }
            catch (e: PackageManager.NameNotFoundException) { /* next */ }
        }
        return null
    }

    fun isInstalled(ctx: Context): Boolean = installedId(ctx) != null

    fun installedVersion(ctx: Context): String? {
        val id = installedId(ctx) ?: return null
        return try {
            @Suppress("DEPRECATION")
            ctx.packageManager.getPackageInfo(id, 0).versionName
        } catch (e: PackageManager.NameNotFoundException) { null }
    }
}

/**
 * Public API for the hub's fleet updater. Same shape as ea_cloud-superapp's
 * Updater (start/cancel/checkNow), but it manages the WHOLE constellation —
 * itself + every fork — driven entirely by build.json::release.auto_update +
 * the baked fleet. Call [start] once from App.onCreate.
 */
object FleetUpdater {
    private const val WORK_NAME = "comms-fleet-auto-update"
    private const val ONE_SHOT_NAME = "comms-fleet-update-now"

    /** The constellation, in priority order (hub first). Data-driven. */
    val fleet: List<FleetEntry> by lazy { parseFleet() }

    fun start(context: Context) {
        if (!BuildConfig.AUTO_UPDATE_ENABLED) { cancel(context); return }
        val constraints = Constraints.Builder().apply {
            setRequiredNetworkType(if (BuildConfig.AU_REQUIRE_UNMETERED) NetworkType.UNMETERED else NetworkType.CONNECTED)
            if (BuildConfig.AU_REQUIRE_CHARGING) setRequiresCharging(true)
        }.build()
        val request = PeriodicWorkRequestBuilder<UpdateWorker>(
            BuildConfig.AUTO_UPDATE_INTERVAL_HOURS, TimeUnit.HOURS,
        ).setConstraints(constraints).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request,
        )
    }

    fun cancel(context: Context) =
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME).let { }

    /** One-shot manual check (the About "Check for updates" button). REPLACE so
        rapid taps cancel the previous run. */
    fun checkNow(context: Context) {
        val request = OneTimeWorkRequestBuilder<UpdateWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            ONE_SHOT_NAME, ExistingWorkPolicy.REPLACE, request,
        )
    }

    private fun parseFleet(): List<FleetEntry> {
        val json = String(Base64.decode(BuildConfig.UPDATE_FLEET_JSON_B64, Base64.DEFAULT))
        val arr = JSONArray(json)
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            FleetEntry(
                label = o.getString("label"),
                displayName = o.optString("name").ifEmpty { o.getString("label") },
                appId = o.getString("app_id"),
                altId = o.optString("alt_id").takeIf { it.isNotEmpty() },
                image = o.getString("image"),
                blocked = o.optBoolean("blocked", false),
            )
        }
    }
}
