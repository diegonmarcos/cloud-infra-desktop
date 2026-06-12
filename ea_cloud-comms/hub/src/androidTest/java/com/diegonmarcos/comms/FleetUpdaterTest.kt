package com.diegonmarcos.comms

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.diegonmarcos.comms.updater.BundledForkInstaller
import com.diegonmarcos.comms.updater.FleetUpdater
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase-1 updater tester (FIRE rule 5). Asserts the fleet is data-driven and
 * complete: hub + the three forks, each with a GHCR image, parsed from
 * BuildConfig (baked from build.json). No network — pure config correctness.
 */
@RunWith(AndroidJUnit4::class)
class FleetUpdaterTest {

    @Test
    fun fleetHasHubPlusAllForks() {
        val fleet = FleetUpdater.fleet
        assertEquals("fleet size (hub + 4 forks)", 5, fleet.size)
        assertEquals("hub is first", "hub", fleet[0].label)
        assertTrue("hub app id", fleet[0].appId == BuildConfig.APPLICATION_ID)
        val labels = fleet.map { it.label }.toSet()
        assertTrue("has mail/chat/matrix/dialer",
            labels.containsAll(setOf("mail", "chat", "matrix", "dialer")))
    }

    @Test
    fun everyFleetEntryHasAnImage() {
        for (e in FleetUpdater.fleet) {
            assertTrue("${e.label} has GHCR image", e.image.isNotBlank())
            assertTrue("${e.label} image namespaced", e.image.startsWith("cloud-comms"))
        }
    }

    @Test
    fun matrixForkIsBlocked() {
        val matrix = FleetUpdater.fleet.first { it.label == "matrix" }
        assertTrue("matrix blocked until Matrix stack ships", matrix.blocked)
    }

    @Test
    fun autoUpdateConfigBaked() {
        assertTrue("auto-update enabled", BuildConfig.AUTO_UPDATE_ENABLED)
        assertTrue("interval > 0", BuildConfig.AUTO_UPDATE_INTERVAL_HOURS > 0)
        assertEquals("tag", "latest", BuildConfig.AUTO_UPDATE_TAG)
    }

    @Test
    fun bundledForkAssetsEnumerateSafely() {
        // The assets/forks dir exists (README keeps it present); .apk bundling
        // happens at build time. With no fork published, the list is empty —
        // the enumeration must not crash and installMissing must be a no-op.
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val domains = BundledForkInstaller.bundledDomains(ctx)
        for (d in domains) assertTrue("bundled domain known", FleetUpdater.fleet.any { it.label == d })
        // Any bundled domain must be a real fork (never 'hub').
        assertTrue("hub is never bundled", !domains.contains("hub"))
    }
}
