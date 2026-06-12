package com.diegonmarcos.comms.updater

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.diegonmarcos.comms.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * WorkManager job: walk the whole fleet (hub + forks), and for each one
 * check → download → install. Scheduled by FleetUpdater.start() at the
 * build.json::release.auto_update.interval_hours cadence, or fired once by
 * FleetUpdater.checkNow(). One uncooperative entry (network, 404) never aborts
 * the rest — failures are logged and the sweep continues.
 */
class UpdateWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        if (!BuildConfig.AUTO_UPDATE_ENABLED) return@withContext Result.success()
        val checker = UpdateChecker(applicationContext)
        val installer = UpdateInstaller(applicationContext)
        var checked = 0
        var anyFailed = false
        val steps = FleetUpdater.fleet.size
        for ((i, entry) in FleetUpdater.fleet.withIndex()) {
            val step = i + 1
            try {
                val update = checker.check(entry, step, steps)
                if (update == null) { checked++; continue }   // up to date / blocked / not published
                Log.i(TAG, "${entry.label}: installing ${update.downloadedTo.name}")
                UpdateProgress.update(UpdateProgress.State.Installing(entry.label, step, steps))
                installer.install(update.downloadedTo, entry.appId)
                checked++
            } catch (t: Throwable) {
                anyFailed = true
                Log.w(TAG, "${entry.label}: check failed: ${t.message}", t)
                UpdateProgress.update(UpdateProgress.State.Failed(entry.label, t.message ?: t.toString()))
            }
        }
        if (!anyFailed) UpdateProgress.update(UpdateProgress.State.UpToDate(checked))
        if (anyFailed) Result.retry() else Result.success()
    }

    companion object { private const val TAG = "Updater/Worker" }
}
