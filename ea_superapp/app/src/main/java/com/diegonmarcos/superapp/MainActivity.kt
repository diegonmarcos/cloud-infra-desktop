package com.diegonmarcos.superapp

import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import com.diegonmarcos.superapp.updater.Updater

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Periodic check (idempotent). Knobs from build.json::release.auto_update.
        Updater.start(applicationContext)

        // Manual button — kicks off the same UpdateWorker as a one-shot so the
        // user can pull a new APK + install it without re-running build.sh
        // phone-install from a dev machine. PackageInstaller will surface the
        // system install prompt at the end if a newer digest is on GHCR.
        findViewById<MaterialButton>(R.id.check_updates_button).setOnClickListener {
            Updater.checkNow(applicationContext)
            Toast.makeText(this, R.string.check_updates_started, Toast.LENGTH_SHORT).show()
        }
    }
}
