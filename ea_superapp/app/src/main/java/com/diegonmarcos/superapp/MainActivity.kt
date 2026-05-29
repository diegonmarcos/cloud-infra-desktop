package com.diegonmarcos.superapp

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.diegonmarcos.superapp.updater.Updater

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        // Schedule the periodic update check (idempotent; only enqueues if not
        // already scheduled). All knobs come from build.json::release.auto_update.
        Updater.start(applicationContext)
    }
}
