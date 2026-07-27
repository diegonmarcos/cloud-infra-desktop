package com.diegonmarcos.ide

import android.content.Context

/**
 * Tiny persisted-preferences accessor for the hub. Defaults come from
 * BuildConfig (baked from build.json::ui) so the shipped default stays
 * data-driven; the user's choice overrides it in SharedPreferences.
 */
object IdePrefs {
    private const val FILE = "cloud_ide_prefs"
    private const val KEY_OVERLAY_NAVBAR   = "overlay_nav_bar"
    private const val KEY_TERMINAL_BACKEND = "terminal_backend"

    const val BACKEND_NIXONDROID = "nix-on-droid"
    const val BACKEND_TERMUX     = "termux"

    private fun sp(ctx: Context) =
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Floating cross-app wrapper bar (NavOverlayService). Default OFF
     *  (build.json::ui.overlay_nav_bar_default) — SuperApp owns the system bar. */
    fun overlayNavBar(ctx: Context): Boolean =
        sp(ctx).getBoolean(KEY_OVERLAY_NAVBAR, BuildConfig.OVERLAY_NAVBAR_DEFAULT)

    fun setOverlayNavBar(ctx: Context, enabled: Boolean) {
        sp(ctx).edit().putBoolean(KEY_OVERLAY_NAVBAR, enabled).apply()
    }

    /** Which shell env a terminal launches into: "nix-on-droid" or "termux".
     *  Default from build.json::ui.terminal_backend_default; user choice overrides.
     *  No terminal component exists yet — this is the persisted foundation a future
     *  terminal will read via RUN_COMMAND-style intents to the chosen app. */
    fun terminalBackend(ctx: Context): String =
        sp(ctx).getString(KEY_TERMINAL_BACKEND, BuildConfig.TERMINAL_BACKEND_DEFAULT)
            ?: BuildConfig.TERMINAL_BACKEND_DEFAULT

    fun setTerminalBackend(ctx: Context, value: String) {
        sp(ctx).edit().putString(KEY_TERMINAL_BACKEND, value).apply()
    }
}
