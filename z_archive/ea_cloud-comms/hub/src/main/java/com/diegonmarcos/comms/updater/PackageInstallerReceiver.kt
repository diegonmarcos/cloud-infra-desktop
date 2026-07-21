package com.diegonmarcos.comms.updater

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import android.widget.Toast
import com.diegonmarcos.comms.R

/**
 * Receives PackageInstaller status callbacks and feeds them into the
 * transaction state machine:
 *
 *  - STATUS_PENDING_USER_ACTION → the confirm Intent is forwarded through
 *    [InstallGate] (current foreground activity, or a notification fallback —
 *    starting it straight from a receiver is restricted and was silently
 *    dropped). The waiting [Transaction] is told so it shows "confirm".
 *  - STATUS_SUCCESS / FAILURE_* → delivered to [InstallBus] so the running
 *    transaction advances on the REAL result instead of blind polling. An
 *    orphan result (no transaction waiting) still surfaces as toast +
 *    notification so silent rejects stay visible.
 */
class PackageInstallerReceiver : BroadcastReceiver() {
    private val tag = "Updater/Receiver"
    private val channel = "comms-updater"
    private val notifId = 0xC0AA

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
        Log.i(tag, "session=$sessionId status=$status msg=$message")

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Tell the transaction (item → WAITING_CONFIRM), then hand the
            // dialog to the foreground activity / notification fallback.
            InstallBus.deliver(sessionId, status, message)
            InstallGate.launch(context, confirm,
                context.getString(R.string.notif_confirm_title),
                context.getString(R.string.notif_confirm_text))
            return
        }

        val consumed = InstallBus.deliver(sessionId, status, message)
        if (consumed) return   // transaction renders the result itself

        // Orphan result — no flow waiting; keep it visible like before.
        when (status) {
            PackageInstaller.STATUS_SUCCESS ->
                surface(context, "Update installed ✓", "A Cloud-Comms app was installed successfully.")
            else -> {
                val label = when (status) {
                    PackageInstaller.STATUS_FAILURE_ABORTED     -> "ABORTED"
                    PackageInstaller.STATUS_FAILURE_BLOCKED     -> "BLOCKED"
                    PackageInstaller.STATUS_FAILURE_CONFLICT    -> "CONFLICT (signature/applicationId mismatch — the APK must share the constellation signing key)"
                    PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "INCOMPATIBLE"
                    PackageInstaller.STATUS_FAILURE_INVALID     -> "INVALID"
                    PackageInstaller.STATUS_FAILURE_STORAGE     -> "STORAGE"
                    else -> "status=$status"
                }
                surface(context, "Update failed: $label", message.ifEmpty { label })
            }
        }
    }

    private fun surface(context: Context, short: String, full: String) {
        try { Toast.makeText(context, short, Toast.LENGTH_LONG).show() } catch (_: Throwable) {}
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(channel, "Updater", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val notif: Notification = Notification.Builder(context, channel)
            .setContentTitle(short)
            .setContentText(full)
            .setStyle(Notification.BigTextStyle().bigText(full))
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setAutoCancel(true)
            .build()
        nm.notify(notifId, notif)
    }
}
