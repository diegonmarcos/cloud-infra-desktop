# PLAN — Cloud Dialer: self-contained updater + delivery fix

## Why the two problems exist (evidence)

### Issue 1 — "cloud-comms never found the updated"
There is **no version/registry file to bump** — update discovery is purely the live GHCR image digest. Three converging causes (all in evidence):
1. **The fork image is never built/published by the default pipeline.** `build`/`release` only run `bundle-forks` (`build.sh:164,175`), which pulls `cloud-comms-dialer:latest` from GHCR or **falls back to stock Fossify upstream APK** (`build.sh:106-114`). `build-fork` + `publish-fork` are **separate manual commands**. So my patched dialer never reaches GHCR → device runs stock Fossify → my edits are invisible.
2. **No published image ⇒ FleetUpdater treats the 404 as "up to date"** (`hub/.../Transaction.kt:218-243`).
3. **Real bug**: the installed-digest check uses `e.appId` only, not the actually-installed id (`Transaction.kt:246` + `installedApkSha256` `:500`). The bundled dialer installs under altId `org.fossify.phone`; everywhere else walks both ids (`FleetUpdater.kt:32-38`, `ForkRegistry.kt:27-33`) but this check doesn't → once published it would re-install every cycle.

→ **Fix 1**: patch `Transaction.kt` to use `installedId ?: appId`. **Deliver**: run `build-fork dialer` + `publish-fork dialer` (publishes a new digest). *Blocked in this session: gradle distro download is network-egress-blocked — see Constraint below; delivery runs in CI / a networked shell.*

### Issue 2 — Cloud Dialer has no self-contained updater
The dialer (a Fossify fork) relies on the **hub's** FleetUpdater. The **nav** app (`ea_cloud-nav/libs/updater`) has a proper single-app self-updater. Port that pattern into the dialer fork so it updates **itself** from `ghcr.io/diegonmarcos/cloud-comms-dialer`, with a "Check for updates" UI in Fossify Settings (Configs).

## Updater design (port nav-style, data-driven)
GHCR OCI flow (anon token → manifest → blob), compares **sha256(installed APK) vs manifest layer digest** (not versionCode). Install via **PackageInstaller session** (no FileProvider). ABI-aware tag (`latest` / `latest-x86_64`).

## Patch series additions (on top of existing 0001–0004)

### 0005 — dialer self-updater
- **Kotlin** `app/src/main/kotlin/org/fossify/phone/updater/`: `GhcrClient`, `AbiUpdateTag`, `UpdateChecker`, `UpdateInstaller`, `PackageInstallerReceiver`, `UpdateProgress`, `UpdateWorker` — ported/adapted from `ea_cloud-nav/libs/updater` (package + image retargeted to dialer).
- **gradle** `app/build.gradle.kts`:
  - `buildFeatures { buildConfig = true }` (if not already) + `buildConfigField` for `GHCR_REGISTRY`, `GHCR_NAMESPACE`, `GHCR_IMAGE`, `AUTO_UPDATE_TAG`, `AUTO_UPDATE_ENABLED`, `GIT_SHORT_SHA` — each reads a gradle property with a sane default, e.g.
    `buildConfigField("String","GHCR_IMAGE","\"${project.findProperty("GHCR_IMAGE") ?: "cloud-comms-dialer"}\"")`.
  - `implementation("androidx.work:work-runtime-ktx:2.9.x")` (CoroutineWorker).
- **manifest** `app/src/main/AndroidManifest.xml`: `REQUEST_INSTALL_PACKAGES`, `POST_NOTIFICATIONS`, (INTERNET already present); `<receiver .updater.PackageInstallerReceiver exported=false>`.
- **Settings UI** (Configs): new "Updates" section + `settings_check_for_updates_holder` row appended to `settings_holder` in `res/layout/activity_settings.xml`; `setupCheckForUpdates()` in `SettingsActivity.kt` (added to the `onResume` binder list + label added to the tint `arrayOf`), wired to `UpdateChecker` → `UpdateInstaller` with `UpdateProgress` status text. strings: `updates`, `check_for_updates`, `update_checking`, `update_up_to_date`, `update_downloading`, `update_failed`.

### Engine changes (in `ea_cloud-comms/build.sh` + hub)
- **`step_build_fork`**: pass `-P` props derived from `build.json` (`release.ghcr.{registry,namespace}`, `forks.<key>.image` → `GHCR_IMAGE`, `release.auto_update.tag`, short sha) so BuildConfig is **data-driven from build.json**, not hardcoded.
- **Hub bugfix**: `Transaction.kt:246/500` → use the installed id (alt id) not `appId`.

## Tester (FIRE rule 5)
- Pure-JVM unit test for the version-compare decision (digest-equal ⇒ no update; differ ⇒ update) — mirrors nav's logic, no Android types.
- Patch-integrity: fresh `materialize-fork dialer` `git am`s the full series clean.
- Compile/build + `build-fork`/`publish-fork`: **deferred to a networked env/CI** (see Constraint).

## Constraint (must flag to user)
This sandbox has **no network egress to `services.gradle.org`** → `assembleFossRelease` cannot download the gradle distribution, so the APK cannot be built/published here. The JDK engine fix is verified (gradle now starts). Patches + engine/hub fixes are authored and `git am`-verified; **actual build + `publish-fork dialer` (which is what makes cloud-comms "find the update") must run in CI or a networked shell.**

## Open question
- Self-updater coexisting with the hub FleetUpdater: both would manage the dialer package (harmless — both compare the same GHCR digest). Default: keep both. Disable hub-side dialer updates only if you want the dialer fully autonomous.
