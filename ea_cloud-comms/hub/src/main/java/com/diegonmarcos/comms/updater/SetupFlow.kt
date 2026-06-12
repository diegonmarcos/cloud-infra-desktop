package com.diegonmarcos.comms.updater

import android.content.Context
import android.util.Log
import com.diegonmarcos.comms.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The ALL-OR-NOTHING constellation setup (owner spec 2026-06-12): ONE process
 * that first STAGES every missing child APK (per-app progress: extracting from
 * the embedded bundle, or downloading from GHCR with size/percent), then
 * INSTALLS them one by one (per-app step + system confirm each), with the
 * overlay rendering per-app AND total progress throughout.
 *
 * Triggered automatically on first launch of Cloud-Comms (MainActivity) and
 * reachable from the Update card / fleet updater. PackageInstaller's per-app
 * confirmation dialog is an Android no-root requirement — the flow chains the
 * installs so each confirm immediately leads to the next step.
 */
object SetupFlow {
    private const val TAG = "Updater/Setup"
    private val running = AtomicBoolean(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Forks that the flow would set up: not blocked, not installed, and
     *  obtainable (bundled inside this APK, or published on GHCR). */
    fun pending(ctx: Context): List<FleetEntry> =
        FleetUpdater.fleet.filter { e ->
            e.label != "hub" && !e.blocked && !e.isInstalled(ctx)
        }

    /** True when there's anything to set up. Whether each app is obtainable
     *  (bundled vs GHCR vs not-published-yet) is resolved inside the flow. */
    fun needed(ctx: Context): Boolean = pending(ctx).isNotEmpty()

    /** Kick the whole flow. No-op if already running. */
    fun start(ctx: Context) {
        if (!running.compareAndSet(false, true)) return
        val app = ctx.applicationContext
        scope.launch {
            try { run(app) } finally { running.set(false) }
        }
    }

    private suspend fun run(ctx: Context) {
        val targets = pending(ctx)
        if (targets.isEmpty()) { UpdateProgress.update(UpdateProgress.State.UpToDate(0)); return }
        val steps = targets.size
        Log.i(TAG, "all-or-nothing setup: ${targets.joinToString { it.label }}")

        // ── Phase A: STAGE every APK first (all-or-nothing: nothing installs
        //    until everything is locally present). Bundled = extract from
        //    assets; otherwise GHCR download with live percent.
        val staged = LinkedHashMap<FleetEntry, File>()
        targets.forEachIndexed { i, e ->
            val step = i + 1
            val out = File(ctx.cacheDir, "setup-${e.label}.apk")
            if (BundledForkInstaller.hasBundle(ctx, e.label)) {
                UpdateProgress.update(UpdateProgress.State.Checking(e.label, step, steps))
                ctx.assets.open("forks/${e.label}.apk").use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
                staged[e] = out
            } else {
                // Not bundled — try GHCR; a 404 (fork not published yet) is
                // skipped, NOT fatal: all-or-nothing over what exists today.
                try {
                    UpdateProgress.update(UpdateProgress.State.Checking(e.label, step, steps))
                    val client = GhcrClient(e.image)
                    val layer = client.manifest(BuildConfig.AUTO_UPDATE_TAG, client.token())
                    client.blob(layer.digest, client.token(), out) { bytes, total ->
                        val known = if (total > 0) total else layer.size
                        val pct = if (known > 0) ((bytes * 100) / known).toInt().coerceIn(0, 100) else 0
                        UpdateProgress.update(
                            UpdateProgress.State.Downloading(e.label, pct, bytes, known, step, steps))
                    }
                    staged[e] = out
                } catch (t: Throwable) {
                    Log.i(TAG, "${e.label}: not obtainable yet (${t.message}) — skipped from this run")
                    out.delete()
                }
            }
        }
        if (staged.isEmpty()) { UpdateProgress.update(UpdateProgress.State.UpToDate(0)); return }

        // ── Phase B: INSTALL sequentially. Each PackageInstaller session pops
        //    one system confirm; we wait for the install to land (poll) before
        //    moving to the next step so progress is honest.
        val installer = UpdateInstaller(ctx)
        var done = 0
        var i = 0
        for ((e, apk) in staged) {
            i += 1
            UpdateProgress.update(UpdateProgress.State.Installing(e.label, i, staged.size))
            installer.install(apk, e.appId)
            // Wait up to 120s for the user-confirmed install to complete.
            var waited = 0
            while (waited < 120_000 && !e.isInstalled(ctx)) {
                delay(2_000); waited += 2_000
            }
            if (e.isInstalled(ctx)) done++ else
                Log.w(TAG, "${e.label}: install not confirmed within 120s — continuing")
            apk.delete()
        }
        UpdateProgress.update(UpdateProgress.State.UpToDate(done))
    }
}
