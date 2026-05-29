package com.diegonmarcos.superapp

import android.os.Bundle
import android.view.MenuItem
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.ActionBarDrawerToggle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.GravityCompat
import androidx.drawerlayout.widget.DrawerLayout
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.navigation.NavigationView
import com.diegonmarcos.superapp.updater.Updater

/**
 * Top-level shell. Mounts:
 *   - MaterialToolbar (per-page top buttons via SectionFragment.onCreateOptionsMenu)
 *   - BottomNavigationView (6 sections; menu is bottom_nav.xml mirroring
 *     build.json::ui.sections[].id)
 *   - DrawerLayout + NavigationView (left-side, 2-level menu via drawer_menu.xml
 *     mirroring build.json::ui.sections[].drawer_default_children)
 *
 * Section IDs are kept in lock-step with build.json::ui.sections — when adding
 * a new section, edit build.json + bottom_nav.xml + drawer_menu.xml together.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var drawerLayout: DrawerLayout
    private lateinit var bottomNav: BottomNavigationView
    private lateinit var navigationView: NavigationView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val toolbar: MaterialToolbar = findViewById(R.id.toolbar)
        setSupportActionBar(toolbar)

        drawerLayout = findViewById(R.id.drawer_layout)
        bottomNav = findViewById(R.id.bottom_nav)
        navigationView = findViewById(R.id.navigation_view)

        // Hamburger ↔ drawer affordance in the toolbar.
        val toggle = ActionBarDrawerToggle(
            this, drawerLayout, toolbar,
            R.string.drawer_open, R.string.drawer_close,
        )
        drawerLayout.addDrawerListener(toggle)
        toggle.syncState()

        // Drawer header — show the build identifier so updates are visible.
        navigationView.getHeaderView(0).findViewById<TextView>(R.id.nav_header_build).text =
            "${BuildConfig.VERSION_NAME}  vc:${BuildConfig.VERSION_CODE}"

        // Bottom nav drives the section. Same id → label map is used by the
        // drawer top-level groups so both views stay in sync.
        bottomNav.setOnItemSelectedListener { selectSection(it) }

        // Drawer items below the section heading route to a child; tapping the
        // section heading (parent submenu title) is handled by NavigationView
        // automatically. Children show a toast for now (real handling lands
        // when the per-section module grows real UI).
        navigationView.setNavigationItemSelectedListener { handleDrawerItem(it) }

        // Initial fragment.
        if (savedInstanceState == null) {
            bottomNav.selectedItemId = R.id.nav_mail
        }

        // Auto-update plumbing (unchanged) — start the periodic worker.
        Updater.start(applicationContext)
    }

    /** Returns true when the menu item is consumed (BottomNav callback contract). */
    private fun selectSection(item: MenuItem): Boolean {
        val (id, labelRes) = when (item.itemId) {
            R.id.nav_mail  -> "mail"  to R.string.section_mail
            R.id.nav_feed  -> "feed"  to R.string.section_feed
            R.id.nav_chat  -> "chat"  to R.string.section_chat
            R.id.nav_cal   -> "cal"   to R.string.section_cal
            R.id.nav_vault -> "vault" to R.string.section_vault
            R.id.nav_wg    -> "wg"    to R.string.section_wg
            else -> return false
        }
        val label = getString(labelRes)
        supportActionBar?.title = label
        supportFragmentManager.beginTransaction()
            .replace(R.id.fragment_container, SectionFragment.forSection(id, label))
            .commit()
        return true
    }

    private fun handleDrawerItem(item: MenuItem): Boolean {
        drawerLayout.closeDrawer(GravityCompat.START)
        when (item.itemId) {
            R.id.drawer_check_updates -> {
                Updater.checkNow(applicationContext)
                Toast.makeText(this, R.string.check_updates_started, Toast.LENGTH_SHORT).show()
            }
            else -> Toast.makeText(this, "drawer → ${item.title}", Toast.LENGTH_SHORT).show()
        }
        return true
    }

    override fun onBackPressed() {
        if (drawerLayout.isDrawerOpen(GravityCompat.START)) {
            drawerLayout.closeDrawer(GravityCompat.START)
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }
}
