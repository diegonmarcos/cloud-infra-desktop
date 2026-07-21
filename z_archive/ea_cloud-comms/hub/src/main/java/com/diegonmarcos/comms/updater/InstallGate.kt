package com.diegonmarcos.comms.updater

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.lang.ref.WeakReference

/**
 * Foreground-activity gate for intents that MUST come from an Activity:
 * PackageInstaller's STATUS_PENDING_USER_ACTION confirm dialog and the
 * ACTION_MANAGE_UNKNOWN_APP_SOURCES special-access screen. Launching either
 * from a BroadcastReceiver context is restricted (background activity-start)
 * — the silent reason installs "never happened". MainActivity registers
 * itself on resume (weak ref); when no activity is resumed, the intent is
 * parked on a high-priority notification instead so the user can still act.
 */
object InstallGate {
    private const val TAG = "Updater/Gate"
    private const val CHANNEL = "comms-install"
    private const val NOTIF_ID = 0xC0AB

    @Volatile private var resumed: WeakReference<Activity>? = null

    fun register(activity: Activity) {
        resumed = WeakReference(activity)
    }

    fun unregister(activity: Activity) {
        if (resumed?.get() === activity) resumed = null
    }

    /**
     * Fire [intent] from the current foreground activity; fall back to a
     * high-priority notification carrying it as a PendingIntent. Returns true
     * when launched directly from an Activity.
     */
    fun launch(context: Context, intent: Intent, title: String, text: String): Boolean {
        val activity = resumed?.get()
        if (activity != null) {
            try {
                activity.startActivity(intent)
                return true
            } catch (t: Throwable) {
                Log.w(TAG, "foreground launch failed (${t.message}) — notification fallback")
            }
        }
        notifyFallback(context, intent, title, text)
        return false
    }

    private fun notifyFallback(context: Context, intent: Intent, title: String, text: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Install confirmation", NotificationManager.IMPORTANCE_HIGH))
        }
        val pending = PendingIntent.getActivity(
            context, NOTIF_ID, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        val notif: Notification = Notification.Builder(context, CHANNEL)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIF_ID, notif)
    }
}
