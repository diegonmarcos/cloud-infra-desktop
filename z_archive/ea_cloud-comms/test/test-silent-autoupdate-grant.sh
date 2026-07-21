#!/usr/bin/env bash
# Tester for the silent auto-update + "Install unknown apps" grant feature.
#
# Requirement: an app with Auto-update ON (default) installs a new APK WITHOUT
# the user tapping the system dialog (USER_ACTION_NOT_REQUIRED); OFF falls back
# to the normal prompt. A grant row under Configs/About opens the "Install
# unknown apps" special-access screen that makes the silent path actually skip
# the prompt.
#
# This is a STATIC wiring tester (no device): it asserts the exact source
# markers that implement the flow across all constellation apps. Every check
# mirrors a specific edit; a regression that removes the wiring fails here.
#
# Usage: ./test-silent-autoupdate-grant.sh   (run from anywhere)
# Exit 0 = every app wired. Any FAIL = exit 1.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # → ~/git/unix
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
has() { grep -qF "$2" "$ROOT/$1" 2>/dev/null && ok "$3" || bad "$3 ($1)"; }
hasre() { grep -qE "$2" "$ROOT/$1" 2>/dev/null && ok "$3" || bad "$3 ($1)"; }

# ── Kotlin apps: (updater lib path, About-UI path, app label) ──────────────
# nav / superapp share the permButton idiom; ide uses actionButton.
NAV_UPD="ea_cloud-nav/libs/updater/src/main/java/com/diegonmarcos/cloudnav/updater"
NAV_UI="ea_cloud-nav/app/src/main/java/com/diegonmarcos/cloudnav/configs/DevControlFragment.kt"
SUP_UPD="ea_cloud-superapp/libs/updater/src/main/java/com/diegonmarcos/superapp/updater"
# superapp's grant UI moved DevControlFragment → configs/PermissionsFragment.
SUP_UI="ea_cloud-superapp/app/src/main/java/com/diegonmarcos/superapp/configs/PermissionsFragment.kt"
IDE_UPD="ea_cloud-ide/hub/src/main/java/com/diegonmarcos/ide/update"
IDE_UI="ea_cloud-ide/hub/src/main/java/com/diegonmarcos/ide/AboutActivity.kt"

echo "== T1: runtime toggle helper exists per app, default ON =="
for u in "$NAV_UPD" "$SUP_UPD" "$IDE_UPD"; do
  f="$u/AutoUpdatePrefs.kt"
  has "$f" "getBoolean(KEY_SILENT, true)" "AutoUpdatePrefs.silent defaults ON — ${u%%/*}"
  has "$f" "canRequestPackageInstalls()" "AutoUpdatePrefs.canInstallSilently probes grant — ${u%%/*}"
done

echo "== T2: installer gates USER_ACTION on the toggle (ON→NOT_REQUIRED, OFF→REQUIRED) =="
for u in "$NAV_UPD" "$SUP_UPD" "$IDE_UPD"; do
  f="$u/UpdateInstaller.kt"
  has "$f" "AutoUpdatePrefs.silent(context)" "installer reads the toggle — ${u%%/*}"
  has "$f" "USER_ACTION_NOT_REQUIRED" "installer can go silent — ${u%%/*}"
  has "$f" "USER_ACTION_REQUIRED" "installer keeps prompt fallback — ${u%%/*}"
done

echo "== T3: Configs/About exposes the toggle + 'Install unknown apps' grant =="
# nav / ide keep the original silent-toggle idiom.
for f in "$NAV_UI" "$IDE_UI"; do
  has "$f" "Auto-update (silent)" "About shows auto-update status row — ${f##*/}"
  has "$f" "Install unknown apps" "About shows grant status row — ${f##*/}"
  has "$f" "openUnknownAppSourcesSettings" "About wires the grant button — ${f##*/}"
  has "$f" "ACTION_MANAGE_UNKNOWN_APP_SOURCES" "grant opens the right settings screen — ${f##*/}"
  has "$f" "AutoUpdatePrefs.setSilent" "About toggle flips the pref — ${f##*/}"
done
# superapp evolved: Configs→Permissions exposes a MASTER Auto-update toggle
# (AutoUpdatePrefs.setEnabled; silent stays default-ON) + the same grant row.
has "$SUP_UI" "Auto-update" "Permissions shows auto-update row — superapp"
has "$SUP_UI" "Install unknown apps" "Permissions shows grant status row — superapp"
has "$SUP_UI" "openUnknownAppSourcesSettings" "Permissions wires the grant button — superapp"
has "$SUP_UI" "ACTION_MANAGE_UNKNOWN_APP_SOURCES" "grant opens the right settings screen — superapp"
has "$SUP_UI" "AutoUpdatePrefs.setEnabled" "Permissions master toggle flips the pref — superapp"

echo "== T4: build.json declares install_mode=silent default (4 apps) =="
for b in ea_cloud-nav ea_cloud-superapp ea_cloud-ide ea_cloud-comms; do
  hasre "$b/build.json" '"install_mode":[[:space:]]*"silent"' "$b build.json default = silent"
done

echo "== T5: manifests declare REQUEST_INSTALL_PACKAGES =="
has "ea_cloud-superapp/app/src/main/AndroidManifest.xml" "REQUEST_INSTALL_PACKAGES" "superapp manifest grants install"
has "ea_cloud-nav/libs/updater/src/main/AndroidManifest.xml" "REQUEST_INSTALL_PACKAGES" "nav updater manifest grants install"
has "ea_cloud-ide/hub/src/main/AndroidManifest.xml" "REQUEST_INSTALL_PACKAGES" "ide hub manifest grants install"

echo "== T5b: manifests declare UPDATE_PACKAGES_WITHOUT_USER_ACTION =="
# Android 12+ hard requirement for USER_ACTION_NOT_REQUIRED: without this
# install-time permission the OS SILENTLY downgrades every commit to a prompt
# — silent auto-update can never engage, with zero error anywhere. Every app
# whose installer requests NOT_REQUIRED must carry it in its APK manifest.
for m in \
  "ea_cloud-superapp/app/src/main/AndroidManifest.xml superapp" \
  "ea_cloud-wallet/app/src/main/AndroidManifest.xml wallet" \
  "ea_cloud-vault/app/src/main/AndroidManifest.xml vault" \
  "ea_cloud-browser/app/src/main/AndroidManifest.xml browser" \
  "ea_cloud-nav/app/src/main/AndroidManifest.xml nav" \
  "ea_cloud-ide/hub/src/main/AndroidManifest.xml ide-hub"; do
  path="${m% *}"; app="${m##* }"
  has "$path" "UPDATE_PACKAGES_WITHOUT_USER_ACTION" "$app manifest allows silent updates"
done

echo "== T6: mail fork (patch 0050 — silent installer + About toggle/grant) =="
MAIL_PATCH=$(ls "$ROOT"/ea_cloud-comms/forks/mail/patches/0050-*.patch 2>/dev/null | head -1)
if [ -z "$MAIL_PATCH" ]; then
  bad "mail patch 0050 missing"
else
  P="${MAIL_PATCH#$ROOT/}"
  has "$P" "CommsInstaller.java" "0050 adds the PackageInstaller-based installer"
  has "$P" "USER_ACTION_NOT_REQUIRED" "0050 installer can go silent"
  has "$P" "USER_ACTION_REQUIRED" "0050 keeps the prompt fallback"
  has "$P" "autoSilent" "0050 gates install on the runtime toggle"
  has "$P" "getBoolean(PREF_AUTO_SILENT, true)" "0050 toggle defaults ON"
  has "$P" "ACTION_MANAGE_UNKNOWN_APP_SOURCES" "0050 About wires the install grant"
  has "$P" "CommsInstallReceiver" "0050 registers the install status receiver"
  # The always-prompt path must be REMOVED, not re-added. Match the intent
  # CONSTRUCTION (new Intent(Intent.ACTION_VIEW)), not the word in a comment.
  grep -qE "^-.*new Intent\(Intent\.ACTION_VIEW" "$MAIL_PATCH" \
    && ok "0050 removes the always-prompt ACTION_VIEW install path" \
    || bad "0050 does not remove the ACTION_VIEW install path"
  grep -qE "^\+.*new Intent\(Intent\.ACTION_VIEW" "$MAIL_PATCH" \
    && bad "0050 re-adds an ACTION_VIEW install" \
    || ok "0050 adds no new ACTION_VIEW install"
fi

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
