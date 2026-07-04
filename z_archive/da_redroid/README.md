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

## Delivery: BAKED GHCR image (not runtime install)
The app set + Launcher3 layout + theme are **baked into the image in CI** (data-snapshot),
matching this stack's "every service is a GHCR image" rule. CI (`ship-redroid-image.yml`)
boots base redroid once, installs the 58 apps + renders the layout + applies the theme,
snapshots `/data`, and `docker build`s `src/Dockerfile` shipping that snapshot + a first-boot
seed (`src/seed/`). Runtime is just **pull + run** — the container starts fully provisioned
like Waydroid, with **zero runtime install** ("activation mode" is gone).

## Engine (`build.sh`) — default `up`
```
# RUNTIME (local, on-demand):
./build.sh up         # docker pull + run the BAKED image (seed fills /data once) + wait boot
./build.sh down       # docker stop
./build.sh scrcpy     # mirror + control the display over ADB
./build.sh status     # container + baked image + hotseat/workspace

# IMAGE BUILD (CI — heavy; never the 8GB laptop):
./build.sh bake       # boot base + install+layout+theme + snapshot /data + docker build
./build.sh verify     # boot the baked image fresh → assert 58 apps + layout present (TESTER)
./build.sh push       # push to GHCR
./build.sh ship       # bake + verify + push

# bake-internal (run against the transient bake container; not for runtime):
lock | build | check | install | layout | theme | wallpaper | provision | home | undock | clean
```

## Test
- `bash src/test/test.sh` — pure tests (schema, ref resolution, grid, lockfile, layout-SQL render), run anywhere.
- `./build.sh verify` — end-to-end: boots the baked image fresh and asserts every app + the
  Launcher3 layout are present (the CI gate before push).
