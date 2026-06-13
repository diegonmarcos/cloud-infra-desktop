package com.diegonmarcos.comms.updater

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.diegonmarcos.comms.BuildConfig
import com.diegonmarcos.comms.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide observable state of the CURRENT package-manager transaction —
 * one ItemState per package, rendered by MainActivity's transaction overlay.
 * Richer sibling of [UpdateProgress] (which is kept as a thin adapter so the
 * About screen's single-bar renderer keeps working unchanged).
 */
object TxState {

    sealed class Phase {
        object Queued : Phase()
        data class Fetching(val percent: Int, val bytes: Long, val total: Long) : Phase()
        object Verifying : Phase()
        object WaitingConfirm : Phase()
        data class Installing(val percent: Int) : Phase()
        /** APK fully staged; the SYSTEM is verifying/parsing/optimizing — the
         *  platform emits NO progress for this stretch (the classic "stuck at
         *  90%"), so we render a live elapsed-seconds ticker instead of a
         *  frozen determinate bar. */
        data class Finishing(val seconds: Int) : Phase()
        object Done : Phase()
        data class Skipped(val reason: String) : Phase()
        data class Failed(val message: String) : Phase()
    }

    data class ItemState(val label: String, val phase: Phase)

    data class Snapshot(
        val items: List<ItemState>,
        val totalPercent: Int,
        val finished: Boolean,
        /** true → "Setting up Cloud-Comms" (fresh installs); false → "Updating". */
        val setup: Boolean,
        /** "Install unknown apps" special access not granted — the overlay
         *  shows the grant button while the transaction waits. */
        val needsInstallPermission: Boolean = false,
    ) {
        val anyFailed: Boolean get() = items.any { it.phase is Phase.Failed }
    }

    @Volatile var snapshot: Snapshot? = null
        private set

    private var listener: ((Snapshot?) -> Unit)? = null

    fun setListener(l: ((Snapshot?) -> Unit)?) {
        listener = l
        l?.invoke(snapshot)   // replay for a late subscriber (null = idle)
    }

    fun publish(s: Snapshot) {
        snapshot = s
        listener?.invoke(s)
    }

    fun reset() {
        snapshot = null
        listener?.invoke(null)
    }
}

/**
 * THE package-manager transaction: one plan over all targets (default: every
 * non-blocked Pkg that is missing or has a newer GHCR digest), executed in
 * three phases —
 *
 *   FETCH  (all first, all-or-nothing boundary): bundled asset extract or
 *          GHCR download with live percent; 404 → item SKIPPED, not fatal;
 *          installed + digest equal → item DONE (up to date).
 *   VERIFY sha256 of every GHCR-staged file against its manifest digest
 *          (bundled files are trusted — they shipped inside our signed APK).
 *   COMMIT sequential PackageInstaller sessions. Preflights the "Install
 *          unknown apps" special access once (waits for the grant), streams
 *          real install progress via PackageInstaller.SessionCallback, and
 *          advances on the receiver's STATUS_* via [InstallBus] (180s
 *          timeout fallback). Confirm dialogs go through [InstallGate].
 *
 * All entry points (first-launch auto-setup, the Update card, fork-tile taps,
 * UpdateWorker's periodic sweep) run this one code path.
 */
object Transaction {
    private const val TAG = "Updater/Tx"
    private const val PERMISSION_WAIT_MS = 120_000L
    private const val INSTALL_TIMEOUT_MS = 180_000L

    private val running = AtomicBoolean(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** One mutable work item; published immutably via TxState snapshots. */
    private class Item(val pkg: Pkg) {
        var phase: TxState.Phase = TxState.Phase.Queued
        var staged: File? = null
        /** Expected GHCR digest — null = bundled asset (trusted, no verify). */
        var expectedDigest: String? = null
    }

    private val lock = Any()
    private var curItems: List<Item> = emptyList()
    private var curSetup = false
    private var curNeedsPerm = false

    /** True when any non-blocked fork is missing — first-launch auto-trigger. */
    fun setupNeeded(ctx: Context): Boolean =
        PackageCatalog.resolve(ctx).any { it.entry.label != "hub" && it.status is PkgStatus.Missing }

    /** Fire-and-forget for UI entry points. No-op if a run is in flight. */
    fun start(ctx: Context) {
        val app = ctx.applicationContext
        scope.launch { runAll(app) }
    }

    /** Build + run one transaction over the whole fleet. Returns false when
     *  any item FAILED (UpdateWorker maps that to Result.retry). */
    suspend fun runAll(ctx: Context): Boolean {
        if (!running.compareAndSet(false, true)) return true
        return try {
            execute(ctx.applicationContext)
        } catch (t: Throwable) {
            Log.w(TAG, "transaction aborted: ${t.message}", t)
            synchronized(lock) { curItems.forEach { if (!it.phase.isTerminal()) it.phase = TxState.Phase.Failed(t.message ?: "aborted") } }
            finish()
            false
        } finally {
            running.set(false)
        }
    }

    // ── plan + run ──────────────────────────────────────────────────────

    private suspend fun execute(ctx: Context): Boolean {
        // ALL fleet entries become rows — including the hub and blocked forks —
        // so the user always sees the full constellation (hub + 4 = 5 rows),
        // not a filtered subset. Blocked items render as a skipped row in fetch.
        val targets = PackageCatalog.resolve(ctx)
        val items = targets.map { Item(it) }
        synchronized(lock) {
            curItems = items
            curSetup = targets.any { it.status is PkgStatus.Missing }
            curNeedsPerm = false
        }
        Log.i(TAG, "plan: ${items.joinToString { "${it.pkg.entry.label}=${it.pkg.status::class.simpleName}" }}")
        publish(finished = false)

        fetchAll(ctx, items)
        verifyAll(ctx, items)
        commitAll(ctx, items)

        finish()
        return items.none { it.phase is TxState.Phase.Failed }
    }

    // ── Phase FETCH ─────────────────────────────────────────────────────

    private fun fetchAll(ctx: Context, items: List<Item>) {
        val steps = items.size
        items.forEachIndexed { idx, item ->
            val e = item.pkg.entry
            val step = idx + 1
            val missing = item.pkg.status is PkgStatus.Missing
            try {
                // Blocked fork (e.g. Matrix until its stack ships): a visible
                // row, not a vanished one. Skipped, never processed.
                if (item.pkg.status is PkgStatus.Blocked) {
                    setPhase(item, TxState.Phase.Skipped("blocked"))
                    return@forEachIndexed
                }

                // Bundled asset (shipped inside our signed APK, trusted): the
                // PRIMARY source for the forks. If the fork isn't installed,
                // stage it from the bundle — no network, always works offline.
                // Already installed → it's done (the bundle has no version
                // channel; GHCR is the only update path, handled below for
                // forks that publish an image).
                if (BundledForkInstaller.hasBundle(ctx, e.label)) {
                    if (!missing) {
                        // Installed AND we have a GHCR image → still let the
                        // network path below check for a newer build; otherwise
                        // it's up to date.
                        if (e.image.isBlank()) { setPhase(item, TxState.Phase.Done); return@forEachIndexed }
                    } else {
                        setPhase(item, TxState.Phase.Fetching(0, 0L, -1L))
                        UpdateProgress.update(UpdateProgress.State.Checking(e.label, step, steps))
                        val out = File(ctx.cacheDir, "tx-${e.label}.apk")
                        BundledForkInstaller.extractTo(ctx, e.label, out)
                        item.staged = out
                        setPhase(item, TxState.Phase.Fetching(100, out.length(), out.length()))
                        return@forEachIndexed
                    }
                }

                setPhase(item, TxState.Phase.Fetching(0, 0L, -1L))
                UpdateProgress.update(UpdateProgress.State.Checking(e.label, step, steps))
                val client = GhcrClient(e.image)
                // ABI-aware tag resolution (owner spec: the updater must know
                // the system it runs on): try "<tag>-<deviceAbi>" first (per-ABI
                // artifacts, e.g. arm64 phone vs x86_64 Waydroid), then the
                // plain universal tag. Convention: publish-fork pushes
                // :latest for universal APKs, :latest-<abi> for ABI builds.
                val layer = try {
                    val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"
                    try {
                        client.manifest("${BuildConfig.AUTO_UPDATE_TAG}-$abi", client.token())
                    } catch (abiMiss: IOException) {
                        client.manifest(BuildConfig.AUTO_UPDATE_TAG, client.token())
                    }
                } catch (io: IOException) {
                    // No GHCR image (404 / unreachable). Status-aware so the row
                    // never lies: already-installed → up to date (Done); not
                    // installed and not bundled → genuinely unavailable yet.
                    if (!missing) {
                        Log.i(TAG, "${e.label}: installed, no update channel — up to date")
                        setPhase(item, TxState.Phase.Done)
                    } else {
                        Log.i(TAG, "${e.label}: not obtainable (${io.message})")
                        setPhase(item, TxState.Phase.Skipped("not available yet"))
                    }
                    return@forEachIndexed
                }

                if (!missing) {
                    val installedSha = installedApkSha256(ctx, e.appId)
                    if (installedSha != null && "sha256:$installedSha" == layer.digest) {
                        Log.i(TAG, "${e.label}: up to date")
                        setPhase(item, TxState.Phase.Done)
                        return@forEachIndexed
                    }
                    Log.i(TAG, "${e.label}: update available → ${layer.digest}")
                }

                val out = File(ctx.cacheDir,
                    "tx-${e.label}-${layer.digest.substringAfter(':').take(12)}.apk")
                client.blob(layer.digest, client.token(), out) { bytes, total ->
                    val known = if (total > 0) total else layer.size
                    val pct = if (known > 0) ((bytes * 100) / known).toInt().coerceIn(0, 100) else 0
                    setPhase(item, TxState.Phase.Fetching(pct, bytes, known))
                    UpdateProgress.update(
                        UpdateProgress.State.Downloading(e.label, pct, bytes, known, step, steps))
                }
                item.staged = out
                item.expectedDigest = layer.digest
            } catch (t: Throwable) {
                Log.w(TAG, "${e.label}: fetch failed: ${t.message}", t)
                item.staged?.delete(); item.staged = null
                setPhase(item, TxState.Phase.Failed(t.message ?: "fetch failed"))
            }
        }
    }

    // ── Phase VERIFY ────────────────────────────────────────────────────

    private fun verifyAll(ctx: Context, items: List<Item>) {
        val steps = items.size
        items.forEachIndexed { idx, item ->
            val expected = item.expectedDigest ?: return@forEachIndexed
            val staged = item.staged ?: return@forEachIndexed
            setPhase(item, TxState.Phase.Verifying)
            UpdateProgress.update(UpdateProgress.State.Checking(item.pkg.entry.label, idx + 1, steps))
            val got = "sha256:" + sha256(staged)
            if (got != expected) {
                Log.w(TAG, "${item.pkg.entry.label}: digest mismatch $got != $expected")
                staged.delete(); item.staged = null
                setPhase(item, TxState.Phase.Failed("digest mismatch"))
            }
        }
    }

    // ── Phase COMMIT ────────────────────────────────────────────────────

    private suspend fun commitAll(ctx: Context, items: List<Item>) {
        val toInstall = items.filter { it.staged != null }
        if (toInstall.isEmpty()) return

        // PREFLIGHT (root cause 3): without the "Install unknown apps" special
        // access, session.commit() fails silently / the confirm dialog never
        // reliably appears. Ask once, through the foreground activity, and
        // wait for the grant before committing anything.
        if (!ctx.packageManager.canRequestPackageInstalls()) {
            Log.i(TAG, "canRequestPackageInstalls=false — requesting special access")
            synchronized(lock) { curNeedsPerm = true }
            publish(finished = false)
            InstallGate.launch(
                ctx,
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${ctx.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                ctx.getString(R.string.perm_install_title),
                ctx.getString(R.string.perm_install_notif_text),
            )
            var waited = 0L
            while (waited < PERMISSION_WAIT_MS && !ctx.packageManager.canRequestPackageInstalls()) {
                delay(2_000); waited += 2_000
            }
            synchronized(lock) { curNeedsPerm = false }
            if (!ctx.packageManager.canRequestPackageInstalls()) {
                Log.w(TAG, "install permission not granted within ${PERMISSION_WAIT_MS / 1000}s")
                toInstall.forEach {
                    it.staged?.delete(); it.staged = null
                    setPhase(it, TxState.Phase.Failed("install permission not granted"))
                }
                return
            }
            publish(finished = false)
        }

        // Root cause 2: stream REAL install progress via the platform's
        // SessionCallback (the API F-Droid/Play use), mapped sessionId → item.
        val installer = ctx.packageManager.packageInstaller
        val sessionItems = ConcurrentHashMap<Int, Item>()
        val sessionCallback = object : PackageInstaller.SessionCallback() {
            override fun onCreated(sessionId: Int) {}
            override fun onBadgingChanged(sessionId: Int) {}
            override fun onActiveChanged(sessionId: Int, active: Boolean) {}
            override fun onProgressChanged(sessionId: Int, progress: Float) {
                val item = sessionItems[sessionId] ?: return
                if (item.phase.isTerminal()) return
                // Platform semantics: session progress ≤ ~0.9 is APK STAGING
                // (us writing bytes — fast/local); the final stretch (system
                // verify/parse/dexopt) emits nothing. Map staging to a full
                // 0–100 bar, then hand over to the Finishing ticker instead of
                // freezing at 90%.
                if (progress < 0.89f) {
                    val pct = (progress / 0.9f * 100).toInt().coerceIn(0, 100)
                    setPhase(item, TxState.Phase.Installing(pct))
                } else if (item.phase !is TxState.Phase.Finishing
                           && item.phase !is TxState.Phase.WaitingConfirm) {
                    setPhase(item, TxState.Phase.Finishing(0))
                }
            }
            override fun onFinished(sessionId: Int, success: Boolean) {
                // Backup signal — InstallBus.deliver is idempotent per session.
                InstallBus.deliver(
                    sessionId,
                    if (success) PackageInstaller.STATUS_SUCCESS else PackageInstaller.STATUS_FAILURE,
                    "session finished")
            }
        }
        installer.registerSessionCallback(sessionCallback, Handler(Looper.getMainLooper()))

        val writer = UpdateInstaller(ctx)
        try {
            toInstall.forEachIndexed { idx, item ->
                val e = item.pkg.entry
                val apk = item.staged ?: return@forEachIndexed
                setPhase(item, TxState.Phase.Installing(0))
                UpdateProgress.update(UpdateProgress.State.Installing(e.label, idx + 1, toInstall.size))

                val sessionId = try {
                    writer.createAndWrite(apk, e.appId)
                } catch (t: Throwable) {
                    Log.w(TAG, "${e.label}: session write failed: ${t.message}", t)
                    setPhase(item, TxState.Phase.Failed(t.message ?: "session write failed"))
                    apk.delete(); item.staged = null
                    return@forEachIndexed
                }
                sessionItems[sessionId] = item

                // Root cause 1: the receiver's STATUS_* now lands here and
                // completes the deferred — no more hanging at "Installing…".
                val result = CompletableDeferred<Pair<Int, String>>()
                InstallBus.register(sessionId) { status, msg ->
                    if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                        setPhase(item, TxState.Phase.WaitingConfirm)
                    } else {
                        result.complete(status to msg)
                    }
                }
                try {
                    writer.commit(sessionId)
                    // Await the real result with a 3s liveness ticker: during
                    // the platform's silent verify/optimize stretch the row
                    // shows "finishing… (Xs)" counting up — visibly alive, never
                    // a frozen bar. WaitingConfirm is never overwritten.
                    var r: Pair<Int, String>? = null
                    val startedAt = android.os.SystemClock.elapsedRealtime()
                    while (true) {
                        r = withTimeoutOrNull(3_000L) { result.await() }
                        if (r != null) break
                        val elapsed = android.os.SystemClock.elapsedRealtime() - startedAt
                        if (elapsed >= INSTALL_TIMEOUT_MS) break
                        val ph = item.phase
                        if (ph is TxState.Phase.Installing || ph is TxState.Phase.Finishing) {
                            setPhase(item, TxState.Phase.Finishing((elapsed / 1000).toInt()))
                        }
                    }
                    val res = r
                    when {
                        res == null -> {
                            // Timeout fallback: a fresh install that landed
                            // anyway still counts.
                            val landed = item.pkg.status is PkgStatus.Missing && e.isInstalled(ctx)
                            setPhase(item,
                                if (landed) TxState.Phase.Done
                                else TxState.Phase.Failed("no installer result within ${INSTALL_TIMEOUT_MS / 1000}s"))
                        }
                        res.first == PackageInstaller.STATUS_SUCCESS ->
                            setPhase(item, TxState.Phase.Done)
                        else ->
                            setPhase(item, TxState.Phase.Failed(
                                statusLabel(res.first) + (if (res.second.isNotBlank()) " — ${res.second}" else "")))
                    }
                } finally {
                    InstallBus.unregister(sessionId)
                    sessionItems.remove(sessionId)
                    apk.delete(); item.staged = null
                }
            }
        } finally {
            installer.unregisterSessionCallback(sessionCallback)
        }
    }

    // ── state publishing ────────────────────────────────────────────────

    private fun TxState.Phase.isTerminal(): Boolean =
        this is TxState.Phase.Done || this is TxState.Phase.Skipped || this is TxState.Phase.Failed

    private fun setPhase(item: Item, phase: TxState.Phase) {
        synchronized(lock) { item.phase = phase }
        publish(finished = false)
    }

    private fun itemPercent(p: TxState.Phase): Int = when (p) {
        is TxState.Phase.Queued -> 0
        is TxState.Phase.Fetching -> p.percent / 2
        is TxState.Phase.Verifying -> 55
        is TxState.Phase.WaitingConfirm -> 60
        is TxState.Phase.Installing -> 60 + (p.percent * 35 / 100)
        is TxState.Phase.Finishing -> 95
        is TxState.Phase.Done, is TxState.Phase.Skipped, is TxState.Phase.Failed -> 100
    }

    private fun publish(finished: Boolean) {
        val snap = synchronized(lock) {
            val states = curItems.map { TxState.ItemState(it.pkg.entry.displayName, it.phase) }
            val total = if (states.isEmpty()) 100
                else states.sumOf { itemPercent(it.phase) } / states.size
            TxState.Snapshot(states, total, finished, curSetup, curNeedsPerm)
        }
        TxState.publish(snap)
    }

    private fun finish() {
        publish(finished = true)
        // Thin UpdateProgress adapter — About's single-bar renderer keeps working.
        val failed = synchronized(lock) {
            curItems.firstOrNull { it.phase is TxState.Phase.Failed }
        }
        if (failed != null) {
            val msg = (failed.phase as TxState.Phase.Failed).message
            UpdateProgress.update(UpdateProgress.State.Failed(failed.pkg.entry.label, msg))
        } else {
            val done = synchronized(lock) { curItems.count { it.phase is TxState.Phase.Done } }
            UpdateProgress.update(UpdateProgress.State.UpToDate(done))
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────

    private fun statusLabel(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE_ABORTED      -> "ABORTED (user cancelled)"
        PackageInstaller.STATUS_FAILURE_BLOCKED      -> "BLOCKED"
        PackageInstaller.STATUS_FAILURE_CONFLICT     -> "CONFLICT (signature/applicationId mismatch)"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "INCOMPATIBLE"
        PackageInstaller.STATUS_FAILURE_INVALID      -> "INVALID"
        PackageInstaller.STATUS_FAILURE_STORAGE      -> "STORAGE"
        else -> "status=$status"
    }

    /** sha256 of an installed package's APK, or null if not installed. */
    private fun installedApkSha256(ctx: Context, pkg: String): String? {
        val info = try {
            ctx.packageManager.getPackageInfo(pkg, 0)
        } catch (e: android.content.pm.PackageManager.NameNotFoundException) {
            return null
        }
        val path = info.applicationInfo?.sourceDir ?: return null
        return try { sha256(File(path)) } catch (e: FileNotFoundException) { null }
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { s ->
            val buf = ByteArray(64 * 1024)
            while (true) { val n = s.read(buf); if (n <= 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
