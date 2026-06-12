package com.diegonmarcos.comms.updater

import android.content.Context

/**
 * Package-manager view of one fleet entry. [PkgStatus] is what the local
 * device knows WITHOUT network: installed (with version), missing, or blocked.
 * UPDATE_AVAILABLE / UNAVAILABLE are discovered later, inside a
 * [Transaction]'s FETCH phase (GHCR manifest probe) — resolve() never touches
 * the network, so the catalog is instant and safe to call from UI paths.
 */
sealed class PkgStatus {
    data class Installed(val versionName: String) : PkgStatus()
    object Missing : PkgStatus()
    /** Set by the Transaction fetch phase when the GHCR digest differs from
     *  the installed APK's sha256. Never produced by resolve(). */
    data class UpdateAvailable(val remoteDigest: String) : PkgStatus()
    object Blocked : PkgStatus()
    /** Set by the Transaction fetch phase on a 404 (fork not published yet,
     *  not bundled). Never produced by resolve(). */
    object Unavailable : PkgStatus()
}

data class Pkg(val entry: FleetEntry, val status: PkgStatus)

/**
 * Resolves the whole constellation (hub + forks, data-driven from
 * FleetUpdater.fleet) against the local PackageManager. Obtainability
 * (bundled asset vs GHCR vs not-published) is NOT decided here — the
 * Transaction's fetch phase owns that, marking items SKIPPED/UNAVAILABLE.
 */
object PackageCatalog {
    fun resolve(ctx: Context): List<Pkg> =
        FleetUpdater.fleet.map { e ->
            val status = when {
                e.blocked -> PkgStatus.Blocked
                else -> e.installedVersion(ctx)
                    ?.let { v -> PkgStatus.Installed(v) }
                    ?: PkgStatus.Missing
            }
            Pkg(e, status)
        }
}
