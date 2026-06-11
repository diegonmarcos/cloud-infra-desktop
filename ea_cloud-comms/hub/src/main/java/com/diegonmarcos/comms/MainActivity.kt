package com.diegonmarcos.comms

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

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

        // Permanent constellation chrome: the hub's parent is Cloud-SuperApp, so
        // this renders [↑ Cloud-SuperApp]. The forks render the full bar.
        ConstellationBar.build(this, packageName)?.let { root.addView(it) }

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }

        content.addView(TextView(this).apply {
            text = getString(R.string.hub_title)
            textSize = 22f
            setPadding(0, 0, 0, dp(4))
        })
        content.addView(TextView(this).apply {
            text = getString(R.string.hub_subtitle, BuildConfig.IPC_VERSION, BuildConfig.GIT_SHORT_SHA)
            textSize = 12f
            alpha = 0.6f
            setPadding(0, 0, 0, dp(24))
        })

        for (fork in ForkRegistry.forks) {
            content.addView(tileFor(fork))
        }

        // Configs → About (build info, IPC contract, fleet status, updater).
        content.addView(TextView(this).apply {
            text = getString(R.string.about_entry)
            textSize = 15f
            setPadding(dp(20), dp(20), dp(20), dp(20))
            isClickable = true
            setOnClickListener { startActivity(Intent(this@MainActivity, AboutActivity::class.java)) }
        })

        root.addView(content)
        setContentView(root)
    }

    private fun tileFor(fork: Fork): TextView {
        val installed = fork.isInstalled(this)
        val status = when {
            fork.blockedOn != null -> getString(R.string.tile_blocked, fork.blockedOn)
            installed -> getString(R.string.tile_open)
            else -> getString(R.string.tile_not_installed)
        }
        return TextView(this).apply {
            text = "${fork.domain.replaceFirstChar { it.uppercase() }}\n$status"
            textSize = 16f
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
            isClickable = true
            alpha = if (installed && fork.blockedOn == null) 1f else 0.5f
            (layoutParams ?: LinearLayout.LayoutParams(MATCH, WRAP)).also {
                layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(12) }
            }
            setOnClickListener { onTileTapped(fork, installed) }
        }
    }

    private fun onTileTapped(fork: Fork, installed: Boolean) {
        when {
            fork.blockedOn != null ->
                Toast.makeText(this, getString(R.string.tile_blocked, fork.blockedOn), Toast.LENGTH_LONG).show()
            !installed ->
                Toast.makeText(this, getString(R.string.tile_not_installed_long, fork.appId), Toast.LENGTH_LONG).show()
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
