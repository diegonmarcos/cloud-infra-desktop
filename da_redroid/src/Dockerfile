# redroid-cloud — custom redroid image with the Cloud app set BAKED IN as SYSTEM APPS,
# plus the baked Launcher3 layout + theme applied by a first-boot init service. Built by
# `build.sh bake` WITHOUT booting Android (system-app bake) — so it works on any CI runner
# (GitHub-hosted runners have no binder and cannot boot redroid). Runtime = docker pull +
# run; Android installs the /system/app apps at boot and the seed applies layout+theme once.
#
# The build context (dist/context/) is assembled by build.sh bake:
#   system/app/<pkg>/<pkg>.apk              — the 58 apps as system apps
#   system/etc/redroid-cloud/seed.sh        — first-boot layout+theme configurator
#   system/etc/redroid-cloud/layout.sql     — pre-rendered Launcher3 favorites (baked)
#   system/etc/redroid-cloud/theme.sh       — baked theme flags (dark/rotate/wallpaper dim)
#   system/etc/init/redroid-cloud-seed.rc   — init service (on sys.boot_completed)
ARG BASE=redroid/redroid:13.0.0-latest
FROM ${BASE}

# Overlay the assembled /system tree (apps + seed + layout + init service) onto the image.
COPY system /system

LABEL org.opencontainers.image.title="redroid-cloud" \
      org.opencontainers.image.description="redroid with the Cloud app set baked as system apps + baked Launcher3 layout/theme." \
      org.opencontainers.image.source="https://github.com/diegonmarcos/unix"
