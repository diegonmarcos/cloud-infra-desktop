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
 * user gets a system confirm prompt. Unlike ea_cloud-superapp's installer (which
 * only ever installs itself), this takes the TARGET package name so the hub can
 * install/update any constellation app. Same-key signing means an update over an
 * existing install succeeds without uninstall.
 */
internal class UpdateInstaller(private val context: Context) {
    private val tag = "Updater/Install"

    fun install(apk: File, targetPackage: String) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(targetPackage)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
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
            val callback = PendingIntent.getBroadcast(
                context, sessionId,
                Intent(context, PackageInstallerReceiver::class.java).setPackage(context.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(callback.intentSender)
        }
        Log.i(tag, "PackageInstaller session $sessionId committed for $targetPackage (${apk.name})")
    }
}
