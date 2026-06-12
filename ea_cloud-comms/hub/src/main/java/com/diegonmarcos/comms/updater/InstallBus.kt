package com.diegonmarcos.comms.updater

import android.content.pm.PackageInstaller
import java.util.concurrent.ConcurrentHashMap

/**
 * Session-status bus between [PackageInstallerReceiver] and the running
 * [Transaction]. The receiver used to only Toast STATUS_SUCCESS/FAILURE —
 * the flow never learned the result and hung at "Installing…". Now the
 * Transaction registers a per-sessionId callback BEFORE committing, and the
 * receiver delivers every status here, so the state machine advances on the
 * real PackageInstaller result instead of blind polling.
 */
object InstallBus {
    private val waiters = ConcurrentHashMap<Int, (status: Int, message: String) -> Unit>()

    fun register(sessionId: Int, callback: (status: Int, message: String) -> Unit) {
        waiters[sessionId] = callback
    }

    fun unregister(sessionId: Int) {
        waiters.remove(sessionId)
    }

    /**
     * Route a PackageInstaller status to the waiting transaction. Terminal
     * statuses consume the waiter; STATUS_PENDING_USER_ACTION keeps it
     * registered (the final SUCCESS/FAILURE arrives after the user confirms).
     * Returns true when a transaction consumed the status — false means an
     * orphan result (no flow running) the receiver should surface itself.
     */
    fun deliver(sessionId: Int, status: Int, message: String): Boolean {
        val cb =
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) waiters[sessionId]
            else waiters.remove(sessionId)
        cb?.invoke(status, message)
        return cb != null
    }
}
