package com.diegonmarcos.comms

import android.app.Application
import com.diegonmarcos.comms.updater.FleetUpdater

/** Hub application object. Schedules the fleet auto-updater on launch
 *  (data-driven by build.json::release.auto_update; no-op if disabled). */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        FleetUpdater.start(this)
    }
}
