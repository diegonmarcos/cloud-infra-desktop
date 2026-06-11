package com.diegonmarcos.comms

import android.app.Application

/** Hub application object. Kept minimal — the broker surfaces (provider +
 *  service) are component-scoped, not tied to a long-lived Application. */
class App : Application()
