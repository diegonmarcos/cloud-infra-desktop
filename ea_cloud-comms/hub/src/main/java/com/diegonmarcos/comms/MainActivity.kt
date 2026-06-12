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

        // First-run setup: if any fork ships inside this APK but isn't installed
        // yet, offer a one-tap "install all bundled apps" (each still prompts
        // once — Android no-root security). Hidden once everything is installed
        // or when nothing is bundled (forks not published yet).
        val pendingBundled = ForkRegistry.forks.count {
            it.blockedOn == null && !it.isInstalled(this) && BundledForkInstaller.hasBundle(this, it.domain)
        }
        if (pendingBundled > 0) {
            content.addView(Button(this).apply {
                text = getString(R.string.setup_install_all, pendingBundled)
                setOnClickListener {
                    val n = BundledForkInstaller.installMissing(this@MainActivity)
                    Toast.makeText(this@MainActivity,
                        getString(R.string.setup_installing_n, n), Toast.LENGTH_SHORT).show()
                }
            })
        }

        // Configs → About (build info, IPC contract, fleet status, updater) —
        // same card language as the fork tiles.
        content.addView(TextView(this).apply {
            text = getString(R.string.about_entry)
            textSize = 14f
            setTextColor(0xFFB794F4.toInt())
            background = cardBg()
            setPadding(dp(18), dp(16), dp(18), dp(16))
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8) }
            isClickable = true
            setOnClickListener { startActivity(Intent(this@MainActivity, AboutActivity::class.java)) }
        })

        // Scroll container so small screens never clip the tile list.
        root.addView(android.widget.ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            addView(content)
        })
        setContentView(root)

        // Launcher-shortcut dispatch (mirrors Cloud-SuperApp's grammar).
        handleShortcutIntent(intent)
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
                // Embedded-installer model: install the fork that ships INSIDE
                // this APK (no separate download). PackageInstaller prompts once.
                if (BundledForkInstaller.install(this, fork.domain)) {
                    Toast.makeText(this, getString(R.string.tile_installing, fork.domain), Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(this, getString(R.string.tile_not_bundled, fork.domain), Toast.LENGTH_LONG).show()
                }
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
