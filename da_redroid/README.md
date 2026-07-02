# da_redroid

Declarative, data-driven provisioning of a curated Android app set into the local
**Redroid** (`redroid/redroid` Docker) container, plus a fully data-driven Launcher3
layout (hotseat + home-screen workspace + folders) and theme (dark mode + solid-black
wallpaper). Replaces the decommissioned Waydroid stack.

Redroid is a headless Android container reached over **ADB** and viewed with **scrcpy**.
No host Wayland session, no LXC, no binder-HAL sensors — just a rootful docker container
started **on demand** (never at boot). The `binder_linux` kernel module + docker come from
the NixOS host module `configuration_redroid.nix`; the scrcpy launcher + `.desktop` entry
come from the desktop HM module `containers-cloud/redroid.nix`.

## Data model (`build.json`)
Nothing is hardcoded in the engine:
- `apps[]` — 58 packages (F-Droid + GitHub), each `{package,label,group,source}`.
- `src/apps.lock.json` — reproducible pins (versionCode + SRI sha256), produced by `build.sh lock`.
- `launcher` — folders, hotseat, 2-screen workspace on a 6-col grid → rendered into Launcher3's
  `favorites` DB by `src/lib/gen-layout-sql.js`.
- `theme` — dark mode, solid-black wallpaper (dim 1.0).
- `redroid` — container knobs: image, name, adb address/port, `/data` volume, cpu cap, display
  geometry, gpu mode, and AOSP Launcher3 constants.
- `fdroid` — F-Droid API/repo endpoints.

## Engine (`build.sh`)
```
./build.sh lock       # pin F-Droid versionCodes + sha256 -> src/apps.lock.json
./build.sh build      # fetch pinned APK set -> dist/apks/ (prebuilt GH release, else nix)
./build.sh check      # verify lockfile <-> build.json + APK presence
./build.sh up         # docker run/start the container (data-driven args) + wait for boot
./build.sh down       # docker stop
./build.sh install    # adb install every APK (-g grants runtime perms)
./build.sh layout     # render folders+hotseat+workspace into Launcher3 DB
./build.sh theme      # dark mode + solid-black wallpaper
./build.sh provision  # install + layout + theme (idempotent)
./build.sh scrcpy     # mirror + control the display
./build.sh home       # flip HOME launcher to the SuperApp (Phase 2)
./build.sh ship       # lock(if missing) + build + up + provision
./build.sh status | undock | clean
```

## Test
`bash src/test/test.sh` — pure tests (schema, ref resolution, grid, lockfile, layout-SQL render)
run anywhere; live tests (T6/T7) run when the `redroid` container is up.
