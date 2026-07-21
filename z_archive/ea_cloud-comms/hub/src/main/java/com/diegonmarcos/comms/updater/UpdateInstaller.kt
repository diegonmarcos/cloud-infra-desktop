package com.diegonmarcos.comms.updater

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Wraps PackageInstaller — Android's only no-root path to install an APK. The
 * user gets a system confirm prompt. Split in two so the [Transaction] can
 * wire progress + result plumbing BETWEEN session creation and commit:
 * [createAndWrite] returns the sessionId (for SessionCallback progress mapping
 * and InstallBus registration), then [commit] fires the status pipeline whose
 * STATUS_* lands in PackageInstallerReceiver → InstallBus. Same-key signing
 * means an update over an existing install succeeds without uninstall.
 */
internal class UpdateInstaller(private val context: Context) {
    private val tag = "Updater/Install"

    /** Create a session and stream the APK into it. Returns the sessionId —
     *  NOT yet committed: register InstallBus/SessionCallback first. */
    fun createAndWrite(apk: File, targetPackage: String): Int {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            // NO setAppPackageName: it is only a hint, and forcing OUR fork id
            // onto a STOCK upstream APK (real package com.mattermost.rnbeta /
            // org.fossify.phone) made the platform reject the session with
            // INSTALL_FAILED_INVALID_APK "inconsistent with …". The installer
            // reads the true package from the APK itself.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // Without an explicit package source, Android 14/15 Enhanced
                // Confirmation Mode treats the install as an untrusted sideload
                // and RESTRICTS the installed app — Settings then refuses to
                // grant it protected roles (e.g. the dialer fork's default-Phone
                // / call-screening roles) with the "restricted setting" denial.
                // The hub's GHCR fleet updater IS the constellation's app store.
                setPackageSource(PackageInstaller.PACKAGE_SOURCE_STORE)
            }
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("base.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
        }
        Log.i(tag, "session $sessionId staged for $targetPackage (${apk.name})")
        return sessionId
    }

    /** Commit a previously written session. The result arrives as a broadcast
     *  in PackageInstallerReceiver (EXTRA_SESSION_ID identifies it). */
    fun commit(sessionId: Int) {
        val installer = context.packageManager.packageInstaller
        val callback = PendingIntent.getBroadcast(
            context, sessionId,
            Intent(context, PackageInstallerReceiver::class.java).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        installer.openSession(sessionId).use { it.commit(callback.intentSender) }
        Log.i(tag, "session $sessionId committed")
    }
}
