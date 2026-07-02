# redroid-cloud — custom redroid image with the app set + Launcher3 layout + theme
# BAKED IN (not runtime-installed). Built by `build.sh bake` in CI: base redroid is
# booted once, the 58 apps are installed + the home-screen layout rendered + theme
# applied, then /data is snapshotted into data.tar and shipped here. A first-boot init
# service (post-fs-data) seeds that snapshot into the container's /data, so the image
# starts FULLY PROVISIONED like Waydroid with ZERO runtime install. Pushed to GHCR;
# local `build.sh up` = docker pull + docker run.
#
# Build context (dist/) is prepared by build.sh bake: data.tar + the two seed files.
ARG BASE=redroid/redroid:13.0.0-latest
FROM ${BASE}

# Baked /data snapshot (the exact provisioned Android /data from CI).
COPY data.tar /system/etc/redroid-cloud/data.tar
# First-boot seed script + init service (auto-imported from /system/etc/init/).
COPY redroid-cloud-seed.sh /system/etc/redroid-cloud/seed.sh
COPY redroid-cloud-seed.rc /system/etc/init/redroid-cloud-seed.rc

LABEL org.opencontainers.image.title="redroid-cloud" \
      org.opencontainers.image.description="redroid with the Cloud app set + Launcher3 layout + theme baked in (data-snapshot)." \
      org.opencontainers.image.source="https://github.com/diegonmarcos/unix"
