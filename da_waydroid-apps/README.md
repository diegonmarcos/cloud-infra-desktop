# da_waydroid-apps

Declarative, data-driven provisioning of a curated Android app set into the local
**Waydroid** (LineageOS) container on the Surface desktop — plus seeding of the launcher
**hotseat** (the "bottom bar").

Same engine contract as the other `da_*` desktop tools: `build.sh` (engine) + `build.json`
(data). Nothing is hardcoded in the engine — the package list, dock order, F-Droid
endpoints, Waydroid data root and launcher DB are all read from `build.json` or discovered
at runtime.

## What it installs

| Slot | App | Package | Source | Group |
|------|-----|---------|--------|-------|
| 1 (leftmost) | Cloud-SuperApp | `com.diegonmarcos.superapp` | local x86_64 build | core |
| 2 | Acode | `com.foxdebug.acode` | F-Droid | ide |
| 3 | Amaze File Manager | `com.amaze.filemanager` | F-Droid | ide |
| 4 | FairMail | `eu.faircode.email` | F-Droid | comms |
| 5 | Mattermost | `com.mattermost.rnbeta` | F-Droid | comms |
| 6 | Element | `im.vector.app` | F-Droid | comms |
| drawer | Nix-on-Droid | `com.termux.nix` | F-Droid | ide |
| drawer | Fossify Phone/Contacts/Messages | `org.fossify.*` | F-Droid | comms |

The LineageOS hotseat holds **6 slots** (on the live `6_by_5` grid), so the six headline
apps fill the bar in `core → ide → comms` order. Nix-on-Droid and the Fossify suite are
installed but live in the app drawer (`dock_order: null`). **To re-arrange the bar, edit
`dock_order` in `build.json` and re-run `./build.sh dock`** — no code changes.

## Pipeline

```bash
./build.sh lock      # resolve F-Droid suggestedVersionCode + nix-prefetch sha256 -> src/apps.lock.json
./build.sh build     # nix build the pinned APK set -> dist/apks/  (+ copy local cloud-superapp APK)
./build.sh check     # verify lockfile <-> build.json and that every APK is present
./build.sh install   # waydroid app install every APK            (needs a RUNNING session)
./build.sh dock      # seed the hotseat from dock_order           (needs a RUNNING session)
./build.sh status    # session + declared apps + built APKs + live hotseat
./build.sh ship      # lock(if missing) + build + install + dock
./build.sh undock    # restore the most recent launcher.db backup
```

`install` and `dock` require your Wayland session (Waydroid needs a running session).
Start it first: `waydroid session start`.

## Reproducibility

`src/apps.lock.json` pins every remote APK to a versionCode + SRI `sha256`. `src/flake.nix`
fetches only those pinned, hashed URLs, so `nix build` is byte-reproducible on any machine.
`build.sh lock` is the only step that touches the network unpinned — re-run it to bump
versions (like `npm install` regenerating a lockfile).

## Dock seeding is schema-introspecting (not a hardcoded DB write)

The launcher DB filename is grid-dependent (`launcher_<cols>_by_<rows>.db`) so it is
globbed, never assumed. Before writing, the engine:
1. discovers the DB under the Waydroid data root,
2. backs it up to `dist/backups/`,
3. detects the live hotseat slot count,
4. resolves each app's LAUNCHER activity via `cmd package resolve-activity` (data-driven, not hardcoded components),
5. generates escaped SQL (`DELETE` hotseat + `INSERT` per slot), applies it with the launcher stopped, checkpoints WAL, relaunches, and verifies.

A bad edit can crash-loop the launcher; `./build.sh undock` restores the backup.

## Test

```bash
bash src/test/test.sh
```

Pure tests (schema, dock_order contiguity, core→ide→comms order, lockfile consistency, SQL
escaping + slot cap) run anywhere; the live test runs only when a Waydroid session is up.

## Note: Waydroid itself is not yet declarative

`waydroid` is installed on this host but is **not** in any NixOS/home-manager flake
(`grep -ri waydroid ~/git/unix` → nothing). This project provisions *into* Waydroid; making
`virtualisation.waydroid.enable` itself declarative in the Surface host config is a separate,
recommended follow-up.
