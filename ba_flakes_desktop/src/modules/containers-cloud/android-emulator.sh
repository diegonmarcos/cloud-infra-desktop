# android-emulator — profile chooser → boot → wait → provision
#
# Extracted from containers-cloud/android-emulator.nix's `emulatorApp`
# (pkgs.writeShellScriptBin "android-emulator"). Previously the kdialog menu
# list, the profile-id → {gpu,abi} case statement, and the app-install /
# settings-apply bodies were all GENERATED at Nix eval time by
# lib.concatMapStringsSep / map over the `profiles` list (itself
# forms×arches×tiers cross product) and `prov.apps` / `prov.settings`. All of
# that is now ONE runtime script that reads the same data, plus the
# provisioning config, from /etc-equivalent (home-manager)
# ~/.config/cloud-data/android-emulator.json via jq. Nix now only generates
# that JSON (builtins.toJSON of the computed `profiles` list + `prov`) — the
# single source of truth stays android-emulator.json, unchanged.
#
# Two structural (not behavioral) changes from the original inline heredoc,
# required because writeShellApplication forces `set -euo pipefail` (the
# original writeShellScriptBin body only had `set -u`):
#   - the boot-completed poll loop used `test && break` as a bare statement,
#     which under `set -e` would abort the whole script on the first
#     not-yet-booted poll; rewritten as an explicit `if`, which does not
#     trigger -e. Same polling behaviour, same 150×2s timeout.
#   - `adb wait-for-device` gained an explicit `|| true` to keep matching its
#     previous (set -u-only, therefore already non-fatal) tolerance.
# Every other command's fatality is unchanged: kdialog cancel still `exit 0`s,
# a missing AVD still `exit 1`s, provisioning steps stay best-effort
# (`|| true` / `2>/dev/null`) exactly as before.
set -euo pipefail

CONFIG_JSON="${ANDROID_EMULATOR_CONFIG_JSON:-$HOME/.config/cloud-data/android-emulator.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  kdialog --error "Missing/unreadable $CONFIG_JSON.\nRun:\n  cd ~/git/unix/ba_flakes_desktop && ./build.sh switch surface" 2>/dev/null || true
  exit 1
fi

export ANDROID_AVD_HOME="$HOME/.android/avd"
# NixOS host-GPU acceleration: the emulator's bundled GL/Vulkan can't find the
# system driver on its own, so -gpu host/auto fell back to slow software GL
# (felt like "thrashing"). Point it at the NixOS runtime driver dir + host
# Vulkan ICDs so `auto` uses real Intel hardware accel; it still falls back to
# software if unavailable, so the window always opens. Data-driven: discovers
# whatever ICDs the host declares (no hardcoded GPU vendor).
export LD_LIBRARY_PATH="/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
VK_ICD_FILENAMES=""
for _icd in /run/opengl-driver/share/vulkan/icd.d/*.json; do
  [ -e "$_icd" ] && VK_ICD_FILENAMES="$VK_ICD_FILENAMES${VK_ICD_FILENAMES:+:}$_icd"
done
export VK_ICD_FILENAMES
ADB="$(command -v adb)"
EMU="$(command -v emulator)"

# 1. profile chooser — menu tag/description pairs built at runtime from the
#    JSON, e.g.  phone-x86-full "Phone_x86_full (6144M/6c)"
mapfile -t MENU_ARGS < <(jq -r '.profiles[] | .id, (.label + " (" + .hw["hw.ramSize"] + "/" + .hw["hw.cpu.ncore"] + "c)")' "$CONFIG_JSON")
sel="$(kdialog --title "Android Emulator" --menu "Choose a profile to boot:" "${MENU_ARGS[@]}")" || exit 0
avd="superapp-$sel"
if [ ! -d "$ANDROID_AVD_HOME/$avd.avd" ]; then
  kdialog --error "AVD '$avd' not found. Run:\n  cd ~/git/unix/ba_flakes_desktop && ./build.sh switch surface" 2>/dev/null || true
  exit 1
fi

# resolve the chosen profile's GPU mode + ABI (data-driven, per-arch).
# Defaults mirror the original case statement's pre-case assignment, kept as
# a fallback if `sel` somehow doesn't match any profile (shouldn't happen).
gpu="swiftshader_indirect"; abi="x86_64"
PROFILE="$(jq -c --arg id "$sel" '.profiles[] | select(.id == $id)' "$CONFIG_JSON")"
if [ -n "$PROFILE" ]; then
  gpu="$(printf '%s' "$PROFILE" | jq -r '.gpu')"
  abi="$(printf '%s' "$PROFILE" | jq -r '.abi')"
fi

# 2. boot the chosen profile. GPU mode is per-arch (JSON arches[].gpu_mode):
#    x86 → angle_indirect — ANGLE translates guest GLES → Vulkan → REAL Intel
#    Xe hardware (the host Vulkan ICD is wired via VK_ICD_FILENAMES above; this
#    is true GPU acceleration, fit for game design — NOT a software fallback);
#    arm → swiftshader_indirect — a TCG-emulated arm64 guest can't drive host
#    GL translation, so faithful software GLES is correct. CPU: x86 = KVM,
#    arm = software (TCG). Backgrounded; its window opens.
echo "[android-emulator] booting $avd (abi=$abi gpu=$gpu)…"
"$EMU" -avd "$avd" -gpu "$gpu" -no-boot-anim >/dev/null 2>&1 &

# 3. wait for full boot
"$ADB" wait-for-device || true
for _ in {1..150}; do
  status="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  if [ "$status" = "1" ]; then
    break
  fi
  sleep 2
done

# 4. provision (idempotent) ─────────────────────────────────────────────
# Per-app install block. $HOME inside the JSON apk path expands at runtime;
# the `{abi}` token is replaced with the booted profile's ABI ($abi, set
# above) so an arm profile installs the arm64 APK and x86 the x86_64 one — a
# wrong-ABI install would defeat the faithful-ARM-test goal.
jq -c '.provisioning.apps[]' "$CONFIG_JSON" | while IFS= read -r app; do
  pkg="$(printf '%s' "$app" | jq -r '.pkg')"
  apk_tmpl="$(printf '%s' "$app" | jq -r '.apk')"
  if ! "$ADB" shell pm list packages 2>/dev/null | awk -v p="$pkg" 'index($0,p){f=1} END{exit f?0:1}'; then
    APK="${apk_tmpl//'{abi}'/$abi}"
    if [ -f "$APK" ]; then
      echo "[provision] installing $pkg ($abi)…"; "$ADB" install -r "$APK" || true
    else
      kdialog --error "APK not found:\n$APK\n\nBuild it once:\n  cd ~/git/unix/ea_cloud-superapp && SUPERAPP_VARIANT=$abi ./build.sh build" 2>/dev/null || true
    fi
  fi
done

if jq -e '.provisioning.system_dark' "$CONFIG_JSON" >/dev/null 2>&1 && [ "$(jq -r '.provisioning.system_dark' "$CONFIG_JSON")" = "true" ]; then
  "$ADB" shell cmd uimode night yes >/dev/null 2>&1 || true
fi

# data-driven system settings (e.g. disable animations → far less work for
# the software-GLES renderer on this host). `settings` is an optional key.
if jq -e '.provisioning.settings' "$CONFIG_JSON" >/dev/null 2>&1; then
  jq -c '.provisioning.settings[]' "$CONFIG_JSON" | while IFS= read -r s; do
    ns="$(printf '%s' "$s" | jq -r '.ns')"
    key="$(printf '%s' "$s" | jq -r '.key')"
    value="$(printf '%s' "$s" | jq -r '.value')"
    "$ADB" shell settings put "$ns" "$key" "$value" >/dev/null 2>&1 || true
  done
fi

# set the SuperApp as the device HOME launcher
HOME_LAUNCHER="$(jq -r '.provisioning.home_launcher' "$CONFIG_JSON")"
"$ADB" shell cmd package set-home-activity "$HOME_LAUNCHER" >/dev/null 2>&1 || true

# pre-seed the SuperApp's own launcher theme (data-driven; the dark
# cloud_minimalist_black). Written via base64 to avoid the quoting/
# stdin-through-adb breakage that made the plain `cat > file` write silently
# produce no file. run-as works (debug APK). force-stop so the app re-reads
# the pref on next launch.
PKG="$(jq -r '.provisioning.superapp_pkg' "$CONFIG_JSON")"
THEME="$(jq -r '.provisioning.superapp_launcher_theme' "$CONFIG_JSON")"
if "$ADB" shell pm list packages 2>/dev/null | awk -v p="$PKG" 'index($0,p){f=1} END{exit f?0:1}'; then
  THEME_B64="$(printf '%s' "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\" ?><map><string name=\"theme\">$THEME</string></map>" | base64 -w0)"
  "$ADB" shell "run-as $PKG sh -c 'mkdir -p shared_prefs; echo $THEME_B64 | base64 -d > shared_prefs/launcher_theme_prefs.xml'" >/dev/null 2>&1 || true
  "$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
fi

# land on the (SuperApp) home screen
"$ADB" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
echo "[android-emulator] $avd ready."
