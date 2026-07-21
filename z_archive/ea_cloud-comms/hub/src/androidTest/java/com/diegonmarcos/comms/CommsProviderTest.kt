package com.diegonmarcos.comms

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase-1 tester (FIRE rule 5). The hub test APK is signed with the same debug
 * key as the hub, so it holds the signature IPC permission and CAN query the
 * provider — this asserts the read surface is well-formed for every contract
 * table even with zero forks installed.
 *
 * The complementary NEGATIVE test — a DIFFERENTLY-signed APK must get a
 * SecurityException — is inherently a two-app check and lives in CI as a
 * separate module (a throwaway APK signed with a foreign key querying
 * content://<authority>/summary and asserting the throw). Documented here so
 * the conformance suite (Phase 5) wires it.
 */
@RunWith(AndroidJUnit4::class)
class CommsProviderTest {

    private val ctx: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun everyTableReturnsWellFormedCursor() {
        val cr = ctx.contentResolver
        for (table in CommsContract.Tables.ALL) {
            val expected = CommsContract.Columns.forTable(table)
            cr.query(CommsContract.hubUri(table), null, null, null, null).use { c ->
                assertNotNull("cursor for $table must not be null", c)
                // Column set + order must match the contract exactly.
                assertArrayEquals("columns for $table", expected, c!!.columnNames)
                // Zero forks installed in the test harness → empty union.
                assertTrue("$table count must be >= 0", c.count >= 0)
            }
        }
    }

    @Test
    fun unknownTableThrows() {
        val bad = android.net.Uri.parse("content://${CommsContract.AUTHORITY}/not_a_table")
        try {
            ctx.contentResolver.query(bad, null, null, null, null)?.close()
            throw AssertionError("expected IllegalArgumentException for unknown table")
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun contractConstantsMatchBuildConfig() {
        assertTrue(CommsContract.AUTHORITY == BuildConfig.IPC_AUTHORITY)
        assertTrue(CommsContract.PERMISSION == BuildConfig.IPC_PERMISSION)
        assertTrue(CommsContract.VERSION == BuildConfig.IPC_VERSION)
        // One-icon model: the launch action the hub uses to open icon-less forks.
        assertTrue(CommsContract.LAUNCH_ACTION == BuildConfig.LAUNCH_ACTION)
        assertTrue(CommsContract.LAUNCH_ACTION.isNotBlank())
    }
}
