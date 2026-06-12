# Fork: dialer (Fossify Phone)

- **Upstream**: https://github.com/FossifyOrg/Phone.git (GPL-3.0, Kotlin) — the
  maintained Fossify fork of Simple Dialer.
- **App id**: `com.diegonmarcos.comms.dialer` · label **Phone**
- **Tracker**: `ea_upstreams-sources/dialer-fossify/`
- **Pinned**: 1.11.1
- **Role**: the "Dialer" entry under Cloud-SuperApp **Suite ▸ Cloud ▸
  Communications** — SuperApp links to it; Cloud-Comms owns/ships it like the
  other forks (registry-driven: tiles, nav bar, fleet updater, bundle).
- **No server / no exporter**: it's the device dialer — no comms-data tables to
  export; no endpoint in `data/comms-endpoints.json`. It joins the constellation
  for ownership (our signing key, our nav bar, our updater), not for IPC data.

## Status

Registry entry + pin landed. Next steps for the dev agent:

1. `./build.sh materialize-fork dialer`.
2. Patches (same concerns as the other forks, minus exporter): branding
   (applicationId → `com.diegonmarcos.comms.dialer`), OPEN action,
   constellation top bar. **EXCEPTION to the one-icon model: the dialer KEEPS
   its LAUNCHER icon** — Android's default-dialer role and the SuperApp Suite
   grid (LauncherApps resolution) both need a launchable activity.
3. **System roles (owner requirement)** — the fork must request BOTH defaults
   on first run via RoleManager:
   - `ROLE_DIALER` — default Phone app (Fossify Phone already requests this
     upstream; verify the flow survives the applicationId rename — the role
     grant is per-package).
   - `ROLE_CALL_SCREENING` — default spam filter / caller-ID screening. Fossify
     Phone does NOT hold this upstream — the patch adds a `CallScreeningService`
     (manifest: `android.permission.BIND_SCREENING_SERVICE` service +
     `RoleManager.createRequestRoleIntent(ROLE_CALL_SCREENING)` in onboarding)
     so spam filtering defaults to our fork too.
3. First CI build via `workflow_dispatch` (fork=dialer) — `build.gradle_task`
   (`assembleFossRelease`) and `apk_glob` in build.json are a best-guess against
   Fossify's flavor setup; the CI run is the tester, adjust on first red.
   Fossify's signing mechanism differs from FairEmail's keystore.properties —
   verify and extend the engine's `signing` modes if needed.

## Tester

- CI: patch series applies clean on the pin; `build-fork dialer` produces a
  signed APK; installed fork answers the OPEN action.
