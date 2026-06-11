Embedded fork APKs (the "all together in one download" bundle).

This directory is populated AT BUILD TIME by `./build.sh bundle-forks` (called
automatically by `build` / `release`): it pulls each fork's published GHCR image
(cloud-comms-<domain>:latest) into <domain>.apk here, so the single Cloud-Comms
hub APK physically carries the forks inside it. On first launch the hub installs
them via PackageInstaller (BundledForkInstaller).

The .apk files are gitignored (build artifacts, never committed) — this README
keeps the directory present so AssetManager.list("forks") works even when no
fork has been published yet (empty bundle → hub still builds + runs).

Data-driven from build.json::forks (image + blocked_on). A fork that's blocked
or not yet published is simply absent from the bundle.
