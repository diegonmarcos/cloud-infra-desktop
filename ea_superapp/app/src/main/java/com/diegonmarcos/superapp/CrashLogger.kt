package com.diegonmarcos.superapp

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Registers a global Thread.UncaughtExceptionHandler that writes every
 * uncaught crash to a file the developer can pull via adb / file manager.
 *
 * Path: getExternalFilesDir(null)/crashes/<timestamp>.txt
 * Reachable on-device at:
 *   /storage/emulated/0/Android/data/com.diegonmarcos.superapp/files/crashes/
 *
 * After saving, we chain to the previous handler so Android still kills the
 * process (otherwise the app would hang in a half-dead state).
 */
object CrashLogger {
    private const val TAG = "CrashLogger"

    fun install(context: Context) {
        val crashDir = File(context.getExternalFilesDir(null), "crashes").apply { mkdirs() }
        val previous = Thread.getDefaultUncaughtExceptionHandler()

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val timestamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
                val file = File(crashDir, "crash-$timestamp.txt")

                val sw = StringWriter()
                PrintWriter(sw).use { pw ->
                    pw.println("=== Diego Superapp crash ===")
                    pw.println("when:        ${Date()}")
                    pw.println("thread:      ${thread.name}")
                    pw.println("version:     ${BuildConfig.VERSION_NAME} (vc:${BuildConfig.VERSION_CODE})")
                    pw.println("git:         ${BuildConfig.GIT_SHORT_SHA}")
                    pw.println("device:      ${Build.MANUFACTURER} ${Build.MODEL}")
                    pw.println("android:     ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
                    pw.println()
                    throwable.printStackTrace(pw)
                }
                file.writeText(sw.toString())
                Log.e(TAG, "wrote ${file.absolutePath}")
            } catch (saveError: Throwable) {
                Log.e(TAG, "failed to save crash", saveError)
            }
            previous?.uncaughtException(thread, throwable)
        }
    }
}
