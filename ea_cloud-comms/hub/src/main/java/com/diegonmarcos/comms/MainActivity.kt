package com.diegonmarcos.comms

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.diegonmarcos.comms.updater.FleetUpdater
import com.diegonmarcos.comms.updater.InstallGate
import com.diegonmarcos.comms.updater.Transaction
import com.diegonmarcos.comms.updater.TxState

/**
 * The switcher. Renders one tile per fork (data-driven from ForkRegistry, itself
 * fed by build.json::forks). Tapping a tile launches that fork app; a fork that
 * isn't installed or is blocked shows its status instead. This is intentionally
 * thin — the rich UX lives inside each fork; the hub only routes.
 */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
        }

        // Permanent constellation chrome — the full five-entry bar with the
        // current app highlighted. The forks render the same bar.
        ConstellationBar.build(this, packageName)?.let { root.addView(it) }

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(28))
        }

        // Header — same palette as the About page (superapp's DevControl):
        // #E9D8FD bold headline + #99FFFFFF caption.
        content.addView(TextView(this).apply {
            text = getString(R.string.hub_title)
            textSize = 24f
            setTextColor(0xFFE9D8FD.toInt())
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, dp(4), 0, dp(2))
        })
        content.addView(TextView(this).apply {
            text = getString(R.string.hub_subtitle, BuildConfig.IPC_VERSION, BuildConfig.GIT_SHORT_SHA)
            textSize = 12f
            setTextColor(0x99FFFFFF.toInt())
            setPadding(0, 0, 0, dp(20))
        })

        // Tiles live in their own container so they can be REBUILT whenever
        // install state changes (transaction finish, returning to the app) —
        // fixes "installed but the hub still shows not installed" staleness.
        tilesBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(tilesBox)
        refreshTiles()

        // Configs row — TWO entries like Cloud-SuperApp: Update (the ONE
        // package-manager entry point — installs missing forks AND applies
        // updates in a single Transaction) and About.
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) }
            addView(configCard(getString(R.string.config_update_entry)) {
                Transaction.start(this@MainActivity)
            }.apply { (layoutParams as LinearLayout.LayoutParams).rightMargin = dp(10) })
            addView(configCard(getString(R.string.config_about_entry)) {
                startActivity(Intent(this@MainActivity, AboutActivity::class.java))
            })
        })

        // Scroll container so small screens never clip the tile list.
        root.addView(android.widget.ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            addView(content)
        })

        // Fullscreen package-manager transaction view: a dark scrim with one
        // row per package (label + status glyph + per-row progress) and a
        // total bar — visible whenever a Transaction runs, so download AND
        // installation progress are both always on screen.
        val frame = android.widget.FrameLayout(this)
        frame.addView(root)
        overlay = buildTransactionOverlay()
        frame.addView(overlay)
        setContentView(frame)

        // Launcher-shortcut dispatch (mirrors Cloud-SuperApp's grammar).
        handleShortcutIntent(intent)

        // First launch (and any launch with missing children): auto-trigger
        // the SAME Transaction the Update card runs — fetch everything, then
        // install everything, per-package + total progress on the overlay.
        if (Transaction.setupNeeded(this)) {
            root.post { Transaction.start(this) }
        }
    }

    // ── Transaction overlay (package-manager transaction view) ─────────────
    private lateinit var overlay: android.widget.FrameLayout
    private lateinit var ovTitle: TextView
    private lateinit var ovRows: LinearLayout
    private lateinit var ovTotalLabel: TextView
    private lateinit var ovTotalBar: android.widget.ProgressBar
    private lateinit var ovPermText: TextView
    private lateinit var ovPermButton: TextView
    private lateinit var ovDismiss: TextView

    private fun buildTransactionOverlay(): android.widget.FrameLayout {
        val scrim = android.widget.FrameLayout(this).apply {
            setBackgroundColor(0xE6000000.toInt())
            isClickable = true; isFocusable = true
            visibility = android.view.View.GONE
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val pad = dp(24); setPadding(pad, pad, pad, pad)
            layoutParams = android.widget.FrameLayout.LayoutParams(MATCH, MATCH)
        }
        ovTitle = TextView(this).apply {
            setTextColor(0xFFE9D8FD.toInt())
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            textSize = 20f
            gravity = Gravity.CENTER
        }
        // One row per package, rebuilt from each Snapshot.
        ovRows = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply {
                topMargin = dp(16); bottomMargin = dp(8)
            }
        }
        ovTotalLabel = TextView(this).apply {
            text = getString(R.string.overlay_total)
            setTextColor(0x99FFFFFF.toInt())
            textSize = 12f
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(12) }
        }
        ovTotalBar = android.widget.ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = false; max = 100
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(4) }
        }
        ovPermText = TextView(this).apply {
            text = getString(R.string.perm_install_title)
            setTextColor(0xFFB794F4.toInt())
            textSize = 13f
            gravity = Gravity.CENTER
            visibility = android.view.View.GONE
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(16) }
        }
        ovPermButton = TextView(this).apply {
            text = getString(R.string.perm_install_button)
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF7C3AED.toInt())
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(10), dp(24), dp(10))
            visibility = android.view.View.GONE
            layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(8) }
            isClickable = true
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")))
            }
        }
        ovDismiss = TextView(this).apply {
            text = getString(R.string.overlay_dismiss)
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF7C3AED.toInt())
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(10), dp(24), dp(10))
            visibility = android.view.View.GONE
            layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(20) }
            isClickable = true
            setOnClickListener {
                TxState.reset()
                com.diegonmarcos.comms.updater.UpdateProgress.reset()
            }
        }
        column.addView(ovTitle); column.addView(ovRows)
        column.addView(ovTotalLabel); column.addView(ovTotalBar)
        column.addView(ovPermText); column.addView(ovPermButton)
        column.addView(ovDismiss)
        scrim.addView(column)
        return scrim
    }

    override fun onResume() {
        super.onResume()
        // Foreground gate: PackageInstaller confirm dialogs + the unknown-
        // sources settings screen are forwarded through THIS activity.
        InstallGate.register(this)
        TxState.setListener { s ->
            runOnUiThread {
                renderSnapshot(s)
                // Installed-state may have just changed — rebuild the tiles so
                // a finished install is recognized immediately, not on restart.
                if (s?.finished == true) refreshTiles()
            }
        }
        // Coming back from another app / settings — re-resolve install state.
        refreshTiles()
    }

    /** Rebuild the fork tile list from live PackageManager state. */
    private fun refreshTiles() {
        if (!::tilesBox.isInitialized) return
        tilesBox.removeAllViews()
        for (fork in ForkRegistry.forks) {
            tilesBox.addView(tileFor(fork))
        }
    }

    private lateinit var tilesBox: LinearLayout

    override fun onPause() {
        super.onPause()
        TxState.setListener(null)
        InstallGate.unregister(this)
    }

    private fun renderSnapshot(s: TxState.Snapshot?) {
        if (!::overlay.isInitialized) return
        if (s == null) { overlay.visibility = android.view.View.GONE; return }
        overlay.visibility = android.view.View.VISIBLE
        ovTitle.text = getString(
            if (s.setup) R.string.overlay_title_setup else R.string.overlay_title_updating)

        ovRows.removeAllViews()
        for (item in s.items) {
            ovRows.addView(TextView(this).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                textSize = 13f
                setTextColor(rowColor(item.phase))
                text = String.format("%-8s %s", item.label, phaseText(item.phase))
                setPadding(0, dp(2), 0, dp(2))
            })
        }

        ovTotalBar.progress = s.totalPercent
        val needsPerm = s.needsInstallPermission
        ovPermText.visibility = if (needsPerm) android.view.View.VISIBLE else android.view.View.GONE
        ovPermButton.visibility = if (needsPerm) android.view.View.VISIBLE else android.view.View.GONE
        ovDismiss.visibility = if (s.finished) android.view.View.VISIBLE else android.view.View.GONE

        // Clean finish (nothing failed) auto-hides like the old UpToDate state
        // — a background sweep that found everything current never nags.
        if (s.finished && !s.anyFailed) {
            overlay.postDelayed({
                val cur = TxState.snapshot
                if (cur != null && cur.finished && !cur.anyFailed) TxState.reset()
            }, 1500)
        }
    }

    /** Per-row mini progress: glyph + percent, one line per package. */
    private fun phaseText(p: TxState.Phase): String = when (p) {
        is TxState.Phase.Queued         -> getString(R.string.pkg_queued)
        is TxState.Phase.Fetching       -> getString(R.string.pkg_fetching, p.percent)
        is TxState.Phase.Verifying      -> getString(R.string.pkg_verifying)
        is TxState.Phase.WaitingConfirm -> getString(R.string.pkg_confirm)
        is TxState.Phase.Installing     -> getString(R.string.pkg_installing, p.percent)
        is TxState.Phase.Finishing      -> getString(R.string.pkg_finishing, p.seconds)
        is TxState.Phase.Done           -> getString(R.string.pkg_done)
        is TxState.Phase.Skipped        -> getString(R.string.pkg_skipped, p.reason)
        is TxState.Phase.Failed         -> getString(R.string.pkg_failed, p.message)
    }

    /** Accent for in-flight rows, caption tint for settled ones, white for
     *  failures — same dark-purple palette as the rest of the hub. */
    private fun rowColor(p: TxState.Phase): Int = when (p) {
        is TxState.Phase.Fetching, is TxState.Phase.Verifying,
        is TxState.Phase.WaitingConfirm, is TxState.Phase.Installing,
        is TxState.Phase.Finishing -> 0xFFB794F4.toInt()
        is TxState.Phase.Failed -> 0xFFFFFFFF.toInt()
        else -> 0x99FFFFFF.toInt()
    }

    /** Half-width config card (Update / About) — weight=1 each across the row. */
    private fun configCard(label: String, onClick: () -> Unit): TextView =
        TextView(this).apply {
            text = label
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(0xFFB794F4.toInt())
            background = cardBg()
            setPadding(dp(12), dp(16), dp(12), dp(16))
            layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f)
            isClickable = true
            setOnClickListener { onClick() }
        }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShortcutIntent(intent)
    }

    /**
     * Dispatch a launcher-shortcut intent carrying a `shortcut_action` extra,
     * using the same target grammar Cloud-SuperApp uses (action:<name>). The
     * `update` shortcut is an independent launcher icon: it kicks off the fleet
     * updater and opens About so the user sees live progress.
     */
    private fun handleShortcutIntent(intent: Intent?) {
        val action = intent?.getStringExtra(AboutActivity.EXTRA_SHORTCUT_ACTION) ?: return
        // Consume so a config-change / re-entry doesn't re-fire it.
        intent.removeExtra(AboutActivity.EXTRA_SHORTCUT_ACTION)
        when (action) {
            "action:check_updates" -> {
                FleetUpdater.checkNow(this)
                startActivity(Intent(this, AboutActivity::class.java))
            }
            "action:open_about" -> {
                startActivity(Intent(this, AboutActivity::class.java))
            }
        }
    }

    /** Rounded card tile for one fork — same dark-purple visual language as the
     *  About page: #1A1A22 card, state dot (green=installed · purple=installable
     *  · grey=blocked), bold white name, accent status caption. */
    private fun tileFor(fork: Fork): android.view.View {
        val installed = fork.isInstalled(this)
        val ready = installed && fork.blockedOn == null
        val status = when {
            fork.blockedOn != null -> getString(R.string.tile_blocked, fork.blockedOn)
            installed -> getString(R.string.tile_open)
            else -> getString(R.string.tile_not_installed)
        }
        val dotColor = when {
            fork.blockedOn != null -> 0xFF555566.toInt()
            installed -> 0xFF34D399.toInt()
            else -> 0xFF7C3AED.toInt()
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = cardBg()
            setPadding(dp(18), dp(16), dp(18), dp(16))
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(10) }
            isClickable = true
            alpha = if (ready) 1f else 0.75f
            setOnClickListener { onTileTapped(fork, installed) }
        }
        card.addView(android.view.View(this).apply {
            background = android.graphics.drawable.GradientDrawable().apply {
                shape = android.graphics.drawable.GradientDrawable.OVAL
                setColor(dotColor)
            }
            layoutParams = LinearLayout.LayoutParams(dp(10), dp(10)).apply { rightMargin = dp(14) }
        })
        card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(this@MainActivity).apply {
                text = fork.label
                textSize = 16f
                setTextColor(0xFFFFFFFF.toInt())
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(TextView(this@MainActivity).apply {
                text = status
                textSize = 12f
                setTextColor(if (ready) 0xFFB794F4.toInt() else 0x99FFFFFF.toInt())
            })
        })
        return card
    }

    /** Shared rounded-card background — one visual language across the hub. */
    private fun cardBg() = android.graphics.drawable.GradientDrawable().apply {
        cornerRadius = dp(14).toFloat()
        setColor(0xFF1A1A22.toInt())
    }

    private fun onTileTapped(fork: Fork, installed: Boolean) {
        when {
            fork.blockedOn != null ->
                Toast.makeText(this, getString(R.string.tile_blocked, fork.blockedOn), Toast.LENGTH_LONG).show()
            !installed -> {
                // A tap on ANY missing fork runs the same package-manager
                // Transaction: fetch everything, then install everything,
                // per-package + total progress on the overlay.
                Transaction.start(this)
            }
            !openFork(fork) ->
                Toast.makeText(this, getString(R.string.tile_launch_failed), Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * Open an installed fork. One-icon model: forks ship without a launcher
     * icon, so we start them by the declared signature-gated action
     * (contract::launch_action). Falls back to a LAUNCHER intent for a fork that
     * still has its own icon during development. Returns false if neither
     * resolves. Returns true (no-op) for the already-handled branches above.
     */
    private fun openFork(fork: Fork): Boolean {
        // Our patched fork: icon-less, opened via the constellation action.
        val byAction = Intent(CommsContract.LAUNCH_ACTION)
            .setPackage(fork.appId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (byAction.resolveActivity(packageManager) != null) {
            startActivity(byAction); return true
        }
        // Launcher fallback — covers a dev fork that still has its icon AND the
        // STOCK upstream APK (altId) bundled until the patched fork ships.
        for (id in listOfNotNull(fork.appId, fork.altId)) {
            val byLauncher = packageManager.getLaunchIntentForPackage(id)
            if (byLauncher != null) {
                startActivity(byLauncher.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return true
            }
        }
        return false
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    }
}
