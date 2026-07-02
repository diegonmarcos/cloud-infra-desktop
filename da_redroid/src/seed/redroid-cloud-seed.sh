#!/system/bin/sh
# redroid-cloud first-boot /data seed. Runs from an Android init service at
# `post-fs-data` (i.e. AFTER /data is mounted and /system tools are available —
# the correct, non-fragile timing, unlike wrapping the container entrypoint).
#
# If /data has not been seeded yet (no marker), extract the baked snapshot — the
# EXACT /data produced in CI by `build.sh bake` (redroid booted once + the 58 apps
# installed + Launcher3 layout rendered + theme applied). This makes the container
# start FULLY PROVISIONED like Waydroid, with ZERO runtime install.
set -u
MARKER=/data/.redroid-cloud-seeded
SNAP=/system/etc/redroid-cloud/data.tar
[ -e "$MARKER" ] && exit 0
[ -f "$SNAP" ] || { log -t redroid-cloud "no baked snapshot at $SNAP"; exit 0; }
log -t redroid-cloud "seeding baked /data from $SNAP…"
# toybox tar (in /system/bin) preserves perms; restore SELinux contexts after.
/system/bin/tar -x -p -f "$SNAP" -C /data 2>/dev/null || { log -t redroid-cloud "tar extract failed"; exit 1; }
/system/bin/restorecon -R /data 2>/dev/null || true
: > "$MARKER"
log -t redroid-cloud "seed complete."
