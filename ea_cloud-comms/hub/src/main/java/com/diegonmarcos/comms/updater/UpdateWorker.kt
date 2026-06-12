package com.diegonmarcos.comms.updater

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.diegonmarcos.comms.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * WorkManager job: run ONE package-manager [Transaction] over the whole fleet
 * (hub + forks) — fetch all, verify, commit sequentially. Handles both
 * MISSING (install) and digest-mismatch (update) targets in the same plan.
 * Scheduled by FleetUpdater.start() at the
 * build.json::release.auto_update.interval_hours cadence, or fired once by
 * FleetUpdater.checkNow(). One uncooperative entry (network, 404) never
 * aborts the rest — the transaction marks it SKIPPED/FAILED and continues.
 */
class UpdateWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        if (!BuildConfig.AUTO_UPDATE_ENABLED) return@withContext Result.success()
        val ok = Transaction.runAll(applicationContext)
        Log.i(TAG, "transaction sweep finished — ok=$ok")
        if (ok) Result.success() else Result.retry()
    }

    companion object { private const val TAG = "Updater/Worker" }
}
