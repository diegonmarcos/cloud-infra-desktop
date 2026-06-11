package com.diegonmarcos.comms

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.RemoteCallbackList
import android.util.Log

/**
 * The AIDL action + push broker. Implements ICommsService (see the .aidl, which
 * mirrors contract/comms-ipc-v1.json::aidl). Cloud-SuperApp binds this to send /
 * markRead / openInApp / forceSync and to register for push callbacks.
 *
 * Phase 1 wiring: the broker resolves each call to the owning fork via
 * ForkRegistry and forwards it to that fork's exporter service. Until the fork
 * exporters land (Phase 2), actions on an uninstalled/blocked domain return
 * false / no-op rather than throwing, and callbacks are held in a
 * RemoteCallbackList ready for the forks to drive.
 *
 * Exported with the signature IPC permission (see AndroidManifest) — a caller
 * signed with a different key gets SecurityException at bind time.
 */
class CommsService : Service() {

    private val callbacks = RemoteCallbackList<ICommsCallback>()

    private val binder = object : ICommsService.Stub() {
        override fun send(domain: String, accountId: String, threadId: String, body: String): Boolean {
            val fork = available(domain) ?: return false
            Log.d(TAG, "send → ${fork.domain} (forwarding to exporter pending Phase 2)")
            // TODO(Phase 2): bind fork.appId's exporter ICommsService and forward.
            return false
        }

        override fun markRead(domain: String, accountId: String, threadId: String): Boolean {
            val fork = available(domain) ?: return false
            Log.d(TAG, "markRead → ${fork.domain}")
            return false
        }

        override fun openInApp(domain: String, threadId: String) {
            val fork = ForkRegistry.byDomain(domain) ?: return
            // Launch the owning fork; deep-link extras are added when the fork
            // exporters declare their VIEW intent contract (Phase 2).
            val launch = packageManager.getLaunchIntentForPackage(fork.appId) ?: run {
                Log.w(TAG, "openInApp: ${fork.appId} not installed"); return
            }
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            launch.putExtra(EXTRA_THREAD_ID, threadId)
            startActivity(launch)
        }

        override fun forceSync(domain: String) {
            val fork = available(domain) ?: return
            Log.d(TAG, "forceSync → ${fork.domain}")
            // TODO(Phase 2): forward to the fork exporter's forceSync.
        }

        override fun registerCallback(cb: ICommsCallback) { callbacks.register(cb) }
        override fun unregisterCallback(cb: ICommsCallback) { callbacks.unregister(cb) }
    }

    /** A fork is "available" for actions only if installed and not blocked. */
    private fun available(domain: String): Fork? =
        ForkRegistry.byDomain(domain)?.takeIf { it.blockedOn == null && it.isInstalled(this) }

    /** Fan a push out to every registered SuperApp callback. Driven by the fork
        exporters once they report events (Phase 2). */
    fun dispatchNewMessage(domain: String, threadId: String) {
        val n = callbacks.beginBroadcast()
        for (i in 0 until n) {
            try { callbacks.getBroadcastItem(i).onNewMessage(domain, threadId) } catch (_: Throwable) {}
        }
        callbacks.finishBroadcast()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        callbacks.kill()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "CommsService"
        const val EXTRA_THREAD_ID = "com.diegonmarcos.comms.extra.THREAD_ID"
    }
}
