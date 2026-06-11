package com.diegonmarcos.comms.updater

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Minimal OCI registry client for GHCR — mirrors what build.sh oras-pull does:
 *   1. anonymous bearer token from /token
 *   2. manifest GET (vnd.oci.image.manifest.v1+json)
 *   3. blob GET by digest
 *
 * Unlike ea_cloud-superapp's single-image client, this one is constructed
 * PER image so the hub can pull its own APK and each fork's APK from the same
 * code. registry/namespace come from BuildConfig (build.json::release.ghcr);
 * the image is the per-app value from the update fleet. Zero hardcoded strings.
 * Uses built-in org.json (no kotlinx-serialization dependency).
 */
internal class GhcrClient(
    private val image: String,
    private val registry: String = BuildConfig.GHCR_REGISTRY,
    private val namespace: String = BuildConfig.GHCR_NAMESPACE,
) {
    private val repo = "$namespace/$image"

    /** Anonymous bearer token for pull. Public packages: this just works. */
    fun token(): String {
        val url = URL("https://$registry/token?service=$registry&scope=repository:$repo:pull")
        openGet(url, emptyMap()).use { stream ->
            return JSONObject(stream.bufferedReader().readText()).getString("token")
        }
    }

    data class ManifestLayer(val digest: String, val size: Long, val title: String)

    /** First layer (the APK blob — one per artifact). Throws on 404 (no such
        image yet — e.g. a fork that hasn't been built) so the caller can skip. */
    fun manifest(tag: String, token: String): ManifestLayer {
        val url = URL("https://$registry/v2/$repo/manifests/$tag")
        val headers = mapOf(
            "Authorization" to "Bearer $token",
            "Accept" to "application/vnd.oci.image.manifest.v1+json",
        )
        openGet(url, headers).use { stream ->
            val layer = JSONObject(stream.bufferedReader().readText())
                .getJSONArray("layers").getJSONObject(0)
            val title = layer.optJSONObject("annotations")
                ?.optString("org.opencontainers.image.title")
                ?.takeIf { it.isNotEmpty() } ?: "$image.apk"
            return ManifestLayer(layer.getString("digest"), layer.getLong("size"), title)
        }
    }

    /** Streams the blob into [target]; caller verifies sha256 against [digest]. */
    fun blob(
        digest: String, token: String, target: File,
        onProgress: ((bytesRead: Long, totalBytes: Long) -> Unit)? = null,
    ) {
        val url = URL("https://$registry/v2/$repo/blobs/$digest")
        val conn = openConn(url, mapOf("Authorization" to "Bearer $token"))
        if (conn.responseCode !in 200..299) {
            throw IOException("HTTP ${conn.responseCode} for $url: ${conn.errorStream?.bufferedReader()?.readText()}")
        }
        val total = conn.contentLengthLong
        conn.inputStream.use { input ->
            target.outputStream().use { output ->
                val buf = ByteArray(64 * 1024)
                var soFar = 0L
                var lastTick = 0L
                while (true) {
                    val read = input.read(buf)
                    if (read < 0) break
                    output.write(buf, 0, read)
                    soFar += read
                    val now = System.currentTimeMillis()
                    if (now - lastTick >= 80) { onProgress?.invoke(soFar, total); lastTick = now }
                }
                onProgress?.invoke(soFar, total)
            }
        }
    }

    private fun openConn(url: URL, headers: Map<String, String>): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
        }

    private fun openGet(url: URL, headers: Map<String, String>) =
        openConn(url, headers).apply {
            if (responseCode !in 200..299) {
                throw IOException("HTTP $responseCode for $url: ${errorStream?.bufferedReader()?.readText()}")
            }
        }.inputStream
}
