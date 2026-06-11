package com.diegonmarcos.comms

import android.net.Uri

/**
 * Kotlin mirror of `contract/comms-ipc-v1.json`. The authority/permission/version
 * come from BuildConfig (baked from the same contract file at build time, so they
 * can't drift); the table paths + column orders are the stable wire shape every
 * fork exporter and Cloud-SuperApp must agree on.
 *
 * The Phase-5 conformance suite asserts these constants against the JSON.
 */
object CommsContract {
    const val VERSION: Int = BuildConfig.IPC_VERSION
    const val AUTHORITY: String = BuildConfig.IPC_AUTHORITY
    const val PERMISSION: String = BuildConfig.IPC_PERMISSION

    /** Intent action the forks register (icon-less, signature-gated) for the hub
     *  / SuperApp to open them. One-icon model — see contract::launch_action. */
    const val LAUNCH_ACTION: String = BuildConfig.LAUNCH_ACTION

    /** Optional extra on LAUNCH_ACTION: deep-link a specific conversation. */
    const val EXTRA_THREAD_ID: String = "com.diegonmarcos.comms.extra.THREAD_ID"

    /** Per-fork exporter authority for domain d, e.g. mail → ...comms.mail.provider. */
    fun forkAuthority(domain: String): String = "com.diegonmarcos.comms.$domain.provider"

    val DOMAINS = listOf("mail", "chat", "matrix")

    object Tables {
        const val ACCOUNTS = "accounts"
        const val SUMMARY = "summary"
        const val THREADS = "threads"
        const val MESSAGES = "messages"
        val ALL = listOf(ACCOUNTS, SUMMARY, THREADS, MESSAGES)
    }

    /** Column orders MUST match contract/comms-ipc-v1.json::tables.<t>.columns. */
    object Columns {
        val ACCOUNTS = arrayOf("domain", "account_id", "display_name", "server", "state", "last_sync_ts")
        val SUMMARY = arrayOf("domain", "account_id", "unread_count", "total_count", "updated_ts")
        val THREADS = arrayOf("domain", "account_id", "thread_id", "title", "snippet", "unread", "ts")
        val MESSAGES = arrayOf("domain", "account_id", "thread_id", "message_id", "sender", "body_preview", "ts", "flags")

        fun forTable(table: String): Array<String> = when (table) {
            Tables.ACCOUNTS -> ACCOUNTS
            Tables.SUMMARY -> SUMMARY
            Tables.THREADS -> THREADS
            Tables.MESSAGES -> MESSAGES
            else -> emptyArray()
        }
    }

    /** Allowed sync states (contract::states.sync). */
    object SyncState {
        const val IDLE = "idle"
        const val SYNCING = "syncing"
        const val ERROR = "error"
        const val OFFLINE = "offline"
        const val UNCONFIGURED = "unconfigured"
    }

    fun hubUri(table: String): Uri =
        Uri.parse("content://$AUTHORITY/$table")

    fun forkUri(domain: String, table: String): Uri =
        Uri.parse("content://${forkAuthority(domain)}/$table")
}
