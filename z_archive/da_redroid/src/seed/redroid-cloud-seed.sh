#!/system/bin/sh
# redroid-cloud first-boot configurator. The 58 apps are BAKED as system apps in
# /system/app (installed by Android at boot — no runtime install). This script only
# applies the BAKED home-screen layout + theme ONCE, from data shipped inside the image
# (/system/etc/redroid-cloud/), using tools that ship in AOSP (sqlite3, toybox, cmd,
# settings). No adb, no network, no external install — pure in-image self-configuration.
# Triggered by an init service on sys.boot_completed=1 (Launcher3 is up, its DB exists).
set -u
BASE=/system/etc/redroid-cloud
MARK=/data/.redroid-cloud-configured
[ -e "$MARK" ] && exit 0
log -t redroid-cloud "first-boot configure: layout + theme…"

# ── theme (data-driven from the baked theme.sh: DARK, AUTOROTATE, WALLPAPER_DIM) ──
[ -f "$BASE/theme.sh" ] && . "$BASE/theme.sh"
if [ "${DARK:-0}" = "1" ]; then cmd uimode night yes >/dev/null 2>&1; settings put secure ui_night_mode 2 >/dev/null 2>&1; fi
[ "${AUTOROTATE:-0}" = "1" ] && settings put system accelerometer_rotation 1 >/dev/null 2>&1
[ -n "${WALLPAPER_DIM:-}" ] && cmd wallpaper set-dim-amount "$WALLPAPER_DIM" >/dev/null 2>&1

# ── layout: apply the baked Launcher3 favorites SQL (rendered at bake time) ──
LP=com.android.launcher3
DB="$(ls /data/data/$LP/databases/launcher*.db 2>/dev/null | head -n1)"
if [ -n "$DB" ] && [ -f "$BASE/layout.sql" ]; then
  OWN="$(stat -c '%u:%g' "$DB" 2>/dev/null)"
  am force-stop "$LP" >/dev/null 2>&1
  if sqlite3 "$DB" < "$BASE/layout.sql" 2>/dev/null; then
    # sqlite3 ran as root → restore Launcher3's uid + drop stale WAL so it doesn't crash-loop.
    [ -n "$OWN" ] && chown "$OWN" "$DB" 2>/dev/null
    rm -f "$DB-wal" "$DB-shm" 2>/dev/null
    monkey -p "$LP" 1 >/dev/null 2>&1
    log -t redroid-cloud "layout applied."
  else
    log -t redroid-cloud "layout sqlite apply failed"
  fi
else
  log -t redroid-cloud "launcher DB not ready or no baked layout.sql (DB=$DB)"
fi

# ── home search bar: remove the Google/QuickSearchBox widget (data-driven REMOVE_QSB) ──
# Launcher3 draws the top "Google" search bar only when a search-widget provider is
# enabled; disabling the provider removes the bar (no favorites row to delete).
if [ "${REMOVE_QSB:-0}" = "1" ]; then
  pm disable-user --user 0 com.android.quicksearchbox >/dev/null 2>&1
  log -t redroid-cloud "QSB search widget disabled."
fi

# ── location: enabled by default (data-driven LOCATION) ──
if [ "${LOCATION:-0}" = "1" ]; then
  cmd location set-location-enabled true >/dev/null 2>&1
  settings put secure location_mode 3 >/dev/null 2>&1
  settings put secure location_providers_allowed +gps,+network >/dev/null 2>&1
  log -t redroid-cloud "location services enabled (high accuracy)."
fi

# ── permissions: grant EVERY requested dangerous permission to EVERY baked app ──
# System apps in /system/app are not adb-installed, so `adb install -g` never granted
# their runtime perms. Loop the baked apps.list and pm-grant each app's requested
# dangerous permissions (pm grant no-ops on normal/undeclared perms). Data-driven GRANT_ALL.
if [ "${GRANT_ALL:-0}" = "1" ] && [ -f "$BASE/apps.list" ]; then
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    for perm in $(dumpsys package "$pkg" 2>/dev/null | grep -oE 'android\.permission\.[A-Z_]+' | sort -u); do
      pm grant "$pkg" "$perm" >/dev/null 2>&1
    done
  done < "$BASE/apps.list"
  log -t redroid-cloud "runtime permissions granted for all baked apps."
fi

: > "$MARK"
log -t redroid-cloud "configure complete."
