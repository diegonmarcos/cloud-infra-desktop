# PLAN: Cloud Media Center

Status: 2026-07-26. This plan was wrong twice before (see Corrections below) and
is now rewritten around verified facts. Anything not verified is marked as such
— do not restate a guess as fact.

## What this app is

`cloud-media-center` is a **replacement for Google Photos + Samsung Gallery**,
plus our own additions (YouTube, Instagram mirror). It is not a niche photo
viewer — it must cover on-device gallery, cloud library, auto-backup, albums/
search/faces, and then extend past what those apps do.

Fork base: [`IacobIonut01/ReFra`](https://github.com/IacobIonut01/ReFra)
(ex-`IacobIonut01/Gallery`, upstream package `com.dot.gallery`), Kotlin +
Jetpack Compose, upstream Apache-2.0.

Verified upstream facts: minSdk **29**, compileSdk/targetSdk **37**, NDK
**29.0.14033849**, CMake **3.31.6** (native libheif/libde265 JNI), flavor
dimensions `abi` × `ml`, gradle task `assembleArm64V8aNoMLRelease`. Pinned tag
**`5.1.1-51101-nightly`** — the project only ships nightly tags; last plain
semver was `4.3.0`.

Our fork relicenses to **GPL-3.0** (upstream is Apache-2.0) because it links
`com.github.teamnewpipe:NewPipeExtractor` (GPL-3.0) for the YouTube source.

Cloud backend: the **already-deployed** `user-media_photoprism` service
(host `oci-apps`, container port 3013, domain `photos.diegonmarcos.com`, S3
bucket `my-photos` on OCI). **PhotoPrism is the cloud photo manager — this is
settled, do not re-litigate it or propose alternatives.**

## Feature mapping

| Google Photos / Samsung Gallery feature | How we deliver it |
|---|---|
| On-device gallery | ReFra upstream, unchanged |
| Cloud library browsing | PhotoPrism WebDAV `/originals/` — upstream ReFra ALREADY has an ownCloud provider, and ownCloud is WebDAV |
| Auto-backup of camera roll | WorkManager → WebDAV PUT to PhotoPrism `/import/`; PhotoPrism auto-indexes |
| Albums / search / faces / EXIF | PhotoPrism server-side, already running |
| **+ YouTube profile** | NewPipeExtractor (our addition) |
| **+ Instagram profile** | server-side `gallery-dl` → PhotoPrism import dir; ZERO app code |

## Rejected alternative

`Radiokot/photoprism-android-client` is a fine PhotoPrism client but is
**remote-only** — no local device gallery, no backup/sync (its own README
points users at Autosync for that). A Google Photos replacement needs the
local half too, which is the harder half and which ReFra already has. Do not
re-propose this as the base.

## Verified blockers (prominent — nothing ships until these clear)

Source: `~/git/cloud-infra/a_solutions/user-media_photoprism/build.json`.

1. **`originals` is mounted READ-ONLY**
   (`.../originals:/photoprism/originals:ro`). It's an rclone mount of the
   `my-photos` OCI bucket. PhotoPrism is currently a read-only viewer.
2. **There is no import mount at all** — only `photoprism_storage` and the
   read-only `originals`. `/photoprism/import` does not exist on disk.
3. The route was `public: true` with `auth: two_factor` (Authelia). **The
   user has now instructed it must be WG-only, not public.** A parallel agent
   is making that change in the cloud repo right now. WG-gating is expected
   to remove the "Authelia intercepts WebDAV" problem, but whether `wg_only`
   actually bypasses Authelia in this fleet's Caddy deriver is **PENDING
   VERIFICATION** by that agent — treat as unverified until confirmed.

Blockers 1 and 2 mean **no backup code can be written until the PhotoPrism
service itself is changed** (writable import volume + mount). This is a
cloud-repo change, not an app change, and it is out of scope for this repo
until it lands.

## Still open — do not invent answers

- **`build.sh` engine choice.** No engine exists for this app yet. The shared
  comms fork engine
  (`1_cicd/src/scripts/cloud-comms-fork-engine.sh`, which `ea_cloud-mail`
  symlinks) is hub-coupled: it hardcodes `:hub:assembleDebug`, a
  `hub-debug.apk` path, and `com.diegonmarcos.comms.MainActivity`, and its
  dispatch table routes everything through hub-bundle steps.
  `ea_cloud-ide/build.sh` has the same coupling. Options: (a) generalize into
  a neutral `android-fork-engine.sh` — correct, but touches 4 shipping apps;
  (b) a minimal single-fork engine for this app only. **Undecided.**
- **The WebDAV spike.** Nobody has tested whether ReFra's existing
  ownCloud/WebDAV provider can talk to PhotoPrism, and crucially whether it
  can UPLOAD or is read-only. This single answer decides whether backup is a
  config change or a real patch. This is **step 1** of the sequence below —
  a ~20-minute manual test with the stock F-Droid ReFra APK — and it must
  happen before any Kotlin is written.
- Whether NDK `29.0.14033849` / CMake `3.31.6` exist in the flake's pinned
  `nixpkgs/nixos-24.11` androidenv — flagged with a TODO in `flake.nix`,
  **unverified**.
- The PhotoPrism WebDAV app password does not exist yet
  (`photoprism auth add --scope webdav`), and its sops key name is
  unassigned.

## Sequence

- [ ] 1. Manual spike: stock F-Droid ReFra APK against
      `https://photos.diegonmarcos.com` ownCloud/WebDAV provider — does it
      read? does it write? (~20 min, no code)
- [ ] 2. Land the `user-media_photoprism` cloud-repo change: writable
      `import` mount + `wg_only: true` route (owned by a parallel agent;
      verify whether wg_only bypasses Authelia)
- [ ] 3. Create PhotoPrism WebDAV app password, assign its sops key name,
      fill `auth_secret_ref` in `data/media-profiles.json`
- [ ] 4. Decide the `build.sh` engine question above
- [ ] 5. Kotlin patch series: profile picker consuming
      `data/media-profiles.json`, PhotoPrism WebDAV source, NewPipeExtractor
      YouTube source
- [ ] 6. WorkManager backup worker (gated on steps 1-3 above)

## Corrections / history

This document has been wrong twice; both mistakes are recorded so they are
not repeated:

1. **Stale service-prefix table.** An earlier version of this plan (and
   related notes) used the old `aa-sui_` / `ca-dat_` category-prefix table.
   The real, current prefixes are `infra-<area>_` / `user-<area>_` — see
   `reference_cloud-service-prefixes.md`. The old table is stale and no
   directory on disk uses it.
2. **Missed PhotoPrism deployment.** An earlier check wrongly concluded no
   photo server was deployed in the fleet, which produced a wrong-premise
   design: a generated `manifest.json` index, a desktop generator script, a
   brand-new `cloud-media-center` S3 bucket, and the claim that "sync is
   unsolvable because no upload endpoint exists." All of that has been
   deleted from disk. PhotoPrism's WebDAV `/import/` IS the upload endpoint
   (once writable — see Verified blockers above); no new bucket, no generated
   manifest, no desktop generator are needed.
