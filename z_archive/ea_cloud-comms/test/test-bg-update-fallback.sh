#!/usr/bin/env bash
# Tester: every unix APK app's install-confirm survives the background.
#
# BUG (constellation-wide): the 6h auto-update runs in WorkManager. When a
# silent PackageInstaller session needs the "install unknown apps" confirmation,
# Android returns STATUS_PENDING_USER_ACTION → the receiver called
# context.startActivity(confirm). Android 10+ BLOCKS background activity starts,
# so the dialog never showed and the update died invisibly ("auto update not
# working"). Fix: every receiver must fall back to a tap-to-install notification
# (PendingIntent — launchable from the background).
#
# Reference: comms-hub already did this via InstallGate. mail via patch 0056
# (CommsInstallReceiver.notifyConfirm). nav/ide/superapp fixed to match.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
has() { grep -qF "$2" "$ROOT/$1" 2>/dev/null && ok "$3" || bad "$3"; }

NAV="ea_cloud-nav/libs/updater/src/main/java/com/diegonmarcos/cloudnav/updater/PackageInstallerReceiver.kt"
IDE="ea_cloud-ide/hub/src/main/java/com/diegonmarcos/ide/update/PackageInstallerReceiver.kt"
SUP="ea_cloud-superapp/libs/updater/src/main/java/com/diegonmarcos/superapp/updater/PackageInstallerReceiver.kt"
HUB="ea_cloud-comms/hub/src/main/java/com/diegonmarcos/comms/updater/PackageInstallerReceiver.kt"
MAIL="ea_upstreams-sources/mail-fairmail/app/src/main/java/eu/faircode/email/CommsInstallReceiver.java"

echo "== nav / ide / superapp: startActivity wrapped + notification fallback =="
for f in "$NAV" "$IDE" "$SUP"; do
  app="${f%%/*}"
  has "$f" "notifyConfirm(context, confirm)" "$app: falls back to notifyConfirm"
  has "$f" "PendingIntent.getActivity(context" "$app: confirm wrapped as PendingIntent"
  # the old bare, unguarded startActivity must be gone
  grep -Pzo 'FLAG_ACTIVITY_NEW_TASK\)\n\s*context\.startActivity\(confirm\)\n\s*\}' "$ROOT/$f" >/dev/null 2>&1 \
    && bad "$app: startActivity still unguarded (no bg fallback)" \
    || ok "$app: startActivity is guarded"
  # try/catch is NOT enough: Android 10+ drops a blocked bg startActivity
  # WITHOUT throwing, so the catch never runs. The fallback must be gated on a
  # real foreground check, not an exception that never comes.
  if grep -qF "isForeground(context)" "$ROOT/$f" 2>/dev/null; then
    ok "$app: bg fallback gated on foreground check (not a dead try/catch)"
  else
    bad "$app: fallback relies on catch of a non-throwing startActivity"
  fi
done

echo "== comms-hub: already background-safe via InstallGate =="
has "$HUB" "InstallGate.launch(context, confirm" "hub routes confirm through InstallGate (fg activity / notification)"

echo "== mail: background-safe via CommsInstallReceiver (patch 0056) =="
has "$MAIL" "notifyConfirm(ctx, confirm)" "mail falls back to notifyConfirm"
has "$MAIL" "PendingIntent.getActivity" "mail confirm wrapped as PendingIntent"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
