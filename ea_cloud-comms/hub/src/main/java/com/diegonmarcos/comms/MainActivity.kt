package com.diegonmarcos.comms

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Button
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.diegonmarcos.comms.updater.BundledForkInstaller
import com.diegonmarcos.comms.updater.FleetUpdater

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

        for (fork in ForkRegistry.forks) {
            content.addView(tileFor(fork))
        }

        // All-or-nothing setup (owner spec): ONE flow stages every missing
        // child APK (bundle-extract or GHCR download with sizes/percent), then
        // installs them step by step — per-app AND total progress on the
        // overlay. The button re-runs it manually; first launch auto-triggers.
        if (com.diegonmarcos.comms.updater.SetupFlow.needed(this)) {
            content.addView(Button(this).apply {
                text = getString(R.string.setup_install_all,
                    com.diegonmarcos.comms.updater.SetupFlow.pending(this@MainActivity).size)
                setOnClickListener {
                    com.diegonmarcos.comms.updater.SetupFlow.start(this@MainActivity)
                }
            })
        }

        // Configs row — TWO separate entries like Cloud-SuperApp: Update and
        // About, side by side, same card language as the fork tiles.
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) }
            addView(configCard(getString(R.string.config_update_entry)) {
                FleetUpdater.checkNow(this@MainActivity)
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

        // Fullscreen update overlay (superapp's UpdateOverlayFragment pattern):
        // a dark scrim with title + progress + detail, shown whenever the fleet
        // updater is doing anything — so download AND installation progress are
        // visible like every other app's updater, wherever you are in the hub.
        val frame = android.widget.FrameLayout(this)
        frame.addView(root)
        overlay = buildUpdateOverlay()
        frame.addView(overlay)
        setContentView(frame)

        // Launcher-shortcut dispatch (mirrors Cloud-SuperApp's grammar).
        handleShortcutIntent(intent)

        // First launch (and any launch with missing children): auto-trigger the
        // all-or-nothing setup — downloading/extracting then installing EVERY
        // child APK in one flow, exactly like the Update path (owner spec).
        if (com.diegonmarcos.comms.updater.SetupFlow.needed(this)) {
            root.post { com.diegonmarcos.comms.updater.SetupFlow.start(this) }
        }
    }

    // ── Update overlay (port of superapp's UpdateOverlayFragment) ──────────
    private lateinit var overlay: android.widget.FrameLayout
    private lateinit var ovTitle: TextView
    private lateinit var ovStep: TextView
    private lateinit var ovDetail: TextView
    private lateinit var ovBar: android.widget.ProgressBar
    private lateinit var ovTotalBar: android.widget.ProgressBar
    private lateinit var ovTotalLabel: TextView

    private fun buildUpdateOverlay(): android.widget.FrameLayout {
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
        ovBar = android.widget.ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true; max = 100
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply {
                topMargin = dp(16); bottomMargin = dp(8)
            }
        }
        ovStep = TextView(this).apply {
            setTextColor(0xFFB794F4.toInt())
            textSize = 13f
            gravity = Gravity.CENTER
        }
        ovDetail = TextView(this).apply {
            setTextColor(0x99FFFFFF.toInt())
            textSize = 13f
            gravity = Gravity.CENTER
        }
        ovTotalLabel = TextView(this).apply {
            setTextColor(0x99FFFFFF.toInt())
            textSize = 12f
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(18) }
        }
        ovTotalBar = android.widget.ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = false; max = 100
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(4) }
        }
        val dismiss = TextView(this).apply {
            text = getString(R.string.overlay_dismiss)
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF7C3AED.toInt())
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(10), dp(24), dp(10))
            layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(20) }
            isClickable = true
            setOnClickListener { com.diegonmarcos.comms.updater.UpdateProgress.reset() }
        }
        column.addView(ovTitle); column.addView(ovStep); column.addView(ovBar); column.addView(ovDetail)
        column.addView(ovTotalLabel); column.addView(ovTotalBar); column.addView(dismiss)
        scrim.addView(column)
        return scrim
    }

    /** Per-app + total progress for all-or-nothing flow states. */
    private fun renderFlowStep(step: Int, steps: Int, perAppPercent: Int) {
        if (steps > 0) {
            ovStep.text = getString(R.string.overlay_step, step, steps)
            ovTotalLabel.text = getString(R.string.overlay_total)
            ovTotalBar.visibility = android.view.View.VISIBLE
            ovTotalLabel.visibility = android.view.View.VISIBLE
            ovTotalBar.progress = (((step - 1) * 100) + perAppPercent.coerceIn(0, 100)) / steps
        } else {
            ovStep.text = ""
            ovTotalBar.visibility = android.view.View.GONE
            ovTotalLabel.visibility = android.view.View.GONE
        }
    }

    override fun onResume() {
        super.onResume()
        com.diegonmarcos.comms.updater.UpdateProgress.setListener { s ->
            runOnUiThread { renderOverlay(s) }
        }
    }

    override fun onPause() {
        super.onPause()
        com.diegonmarcos.comms.updater.UpdateProgress.setListener(null)
    }

    private fun renderOverlay(s: com.diegonmarcos.comms.updater.UpdateProgress.State) {
        if (!::overlay.isInitialized) return
        when (s) {
            is com.diegonmarcos.comms.updater.UpdateProgress.State.Idle -> overlay.visibility = android.view.View.GONE
            is com.diegonmarcos.comms.updater.UpdateProgress.State.Checking -> {
                overlay.visibility = android.view.View.VISIBLE
                ovBar.isIndeterminate = true
                ovTitle.text = getString(R.string.overlay_checking, s.target)
                ovDetail.text = ""
                renderFlowStep(s.step, s.steps, 0)
            }
            is com.diegonmarcos.comms.updater.UpdateProgress.State.Downloading -> {
                overlay.visibility = android.view.View.VISIBLE
                ovBar.isIndeterminate = false; ovBar.progress = s.percent
                ovTitle.text = getString(R.string.overlay_downloading, s.target, s.percent)
                ovDetail.text = "${s.bytes / 1024} KiB / ${if (s.total > 0) "${s.total / 1024} KiB" else "?"}"
                renderFlowStep(s.step, s.steps, s.percent)
            }
            is com.diegonmarcos.comms.updater.UpdateProgress.State.Installing -> {
                overlay.visibility = android.view.View.VISIBLE
                ovBar.isIndeterminate = true
                ovTitle.text = getString(R.string.overlay_installing, s.target)
                ovDetail.text = getString(R.string.overlay_installing_hint)
                renderFlowStep(s.step, s.steps, 50)
            }
            is com.diegonmarcos.comms.updater.UpdateProgress.State.UpToDate -> {
                ovTitle.text = getString(R.string.overlay_up_to_date, s.checked)
                ovBar.isIndeterminate = false; ovBar.progress = 100
                ovDetail.text = ""
                overlay.postDelayed({ if (com.diegonmarcos.comms.updater.UpdateProgress.state is
                    com.diegonmarcos.comms.updater.UpdateProgress.State.UpToDate)
                    overlay.visibility = android.view.View.GONE }, 1500)
            }
            is com.diegonmarcos.comms.updater.UpdateProgress.State.Failed -> {
                overlay.visibility = android.view.View.VISIBLE
                ovBar.isIndeterminate = false
                ovTitle.text = getString(R.string.overlay_failed, s.target)
                ovDetail.text = s.message
            }
        }
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
                // All-or-nothing (owner spec): a tap on ANY missing fork runs
                // the whole setup flow — stage everything, then install
                // everything, with per-app + total progress on the overlay.
                com.diegonmarcos.comms.updater.SetupFlow.start(this)
            }
            !openFork(fork.appId) ->
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
    private fun openFork(appId: String): Boolean {
        val byAction = Intent(CommsContract.LAUNCH_ACTION)
            .setPackage(appId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (byAction.resolveActivity(packageManager) != null) {
            startActivity(byAction); return true
        }
        val byLauncher = packageManager.getLaunchIntentForPackage(appId)
        if (byLauncher != null) {
            startActivity(byLauncher.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return true
        }
        return false
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    }
}
