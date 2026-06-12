package com.diegonmarcos.comms.updater

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.diegonmarcos.comms.BuildConfig
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest

/**
 * Per-app update check for one fleet entry. Compares the GHCR :tag APK digest
 * against the installed APK's sha256; downloads + verifies the new APK when they
 * differ. Returns null when up to date, blocked, or the image isn't published
 * yet (404 — e.g. a fork that hasn't been built).
 */
internal class UpdateChecker(private val context: Context) {
    private val tag = "Updater/Check"

    data class Update(
        val entry: FleetEntry,
        val remoteDigest: String,
        val remoteSize: Long,
        val downloadedTo: File,
        val isFreshInstall: Boolean,   // fork not yet installed → install, not update
    )

    fun check(entry: FleetEntry, step: Int = 0, steps: Int = 0): Update? {
        if (entry.blocked) { Log.i(tag, "${entry.label}: blocked — skip"); return null }
        UpdateProgress.update(UpdateProgress.State.Checking(entry.label, step, steps))
        val client = GhcrClient(entry.image)
        val layer = try {
            client.manifest(BuildConfig.AUTO_UPDATE_TAG, client.token())
        } catch (e: IOException) {
            // 404 / no token → image not published yet (forks). Not an error.
            Log.i(tag, "${entry.label}: no GHCR image yet (${e.message}) — skip")
            return null
        }

        val installedSha = currentApkSha256(entry.appId)
        val isFresh = installedSha == null
        if (!isFresh && "sha256:$installedSha" == layer.digest) {
            Log.i(tag, "${entry.label}: up to date")
            return null
        }
        Log.i(tag, "${entry.label}: ${if (isFresh) "install" else "update"} available → ${layer.digest}")

        val target = File(context.cacheDir, "fleet-${entry.label}-${layer.digest.substringAfter(':').take(12)}.apk")
        client.blob(layer.digest, client.token(), target) { bytes, total ->
            val known = if (total > 0) total else layer.size
            val pct = if (known > 0) ((bytes * 100) / known).toInt().coerceIn(0, 100) else 0
            UpdateProgress.update(UpdateProgress.State.Downloading(entry.label, pct, bytes, known, step, steps))
        }
        val downloadedSha = "sha256:" + sha256(target)
        if (downloadedSha != layer.digest) {
            target.delete()
            UpdateProgress.update(UpdateProgress.State.Failed(entry.label, "digest mismatch"))
            error("${entry.label}: downloaded $downloadedSha != manifest ${layer.digest}")
        }
        return Update(entry, layer.digest, layer.size, target, isFresh)
    }

    /** sha256 of an installed package's APK, or null if not installed. */
    private fun currentApkSha256(pkg: String): String? {
        val info = try {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)
        } catch (e: PackageManager.NameNotFoundException) {
            return null
        }
        val path = info.applicationInfo?.sourceDir ?: return null
        return try { sha256(File(path)) } catch (e: FileNotFoundException) { null }
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { s ->
            val buf = ByteArray(64 * 1024)
            while (true) { val n = s.read(buf); if (n <= 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
