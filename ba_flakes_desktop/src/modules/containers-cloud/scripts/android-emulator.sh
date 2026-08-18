#!/usr/bin/env bash
set -u
export ANDROID_SDK_ROOT="@sdkRoot@"
export ANDROID_HOME="@sdkRoot@"
export ANDROID_AVD_HOME="$HOME/.android/avd"
export JAVA_HOME="@jdk@/lib/openjdk"
export PATH="@jdk@/bin:@sdk@/bin:@kdialog@/bin:$PATH"
# NixOS host-GPU acceleration: the emulator's bundled GL/Vulkan can't find
# the system driver on its own, so -gpu host/auto fell back to slow software
# GL (felt like "thrashing"). Point it at the NixOS runtime driver dir + host
# Vulkan ICDs so `auto` uses real Intel hardware accel; it still falls back to
# software if unavailable, so the window always opens. Data-driven: discovers
# whatever ICDs the host declares (no hardcoded GPU vendor).
export LD_LIBRARY_PATH="/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
VK_ICD_FILENAMES=""
for _icd in /run/opengl-driver/share/vulkan/icd.d/*.json; do
  [ -e "$_icd" ] && VK_ICD_FILENAMES="$VK_ICD_FILENAMES${VK_ICD_FILENAMES:+:}$_icd"
done
export VK_ICD_FILENAMES
ADB="@sdk@/bin/adb"
EMU="@sdk@/bin/emulator"

# 1. profile chooser
sel="$(kdialog --title "Android Emulator" --menu "Choose a profile to boot:" @menuArgs@)" || exit 0
avd="superapp-$sel"
if [ ! -d "$ANDROID_AVD_HOME/$avd.avd" ]; then
  kdialog --error "AVD '$avd' not found. Run:\n  cd ~/git/cloud-unix/ba_flakes_desktop && ./build.sh switch surface" 2>/dev/null || true
  exit 1
fi

# resolve the chosen profile's GPU mode + ABI (data-driven, per-arch)
gpu="swiftshader_indirect"; abi="x86_64"
case "$sel" in
  @profCase@
esac

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
"$ADB" wait-for-device
for _ in $(seq 1 150); do
  [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 2
done

# 4. provision (idempotent) ─────────────────────────────────────────────
@installApps@

@systemDarkBlock@

# data-driven system settings (e.g. disable animations → far less work for
# the software-GLES renderer on this host).
@applySettings@

# set the SuperApp as the device HOME launcher
"$ADB" shell cmd package set-home-activity "@homeLauncher@" >/dev/null 2>&1 || true

# pre-seed the SuperApp's own launcher theme (data-driven; the dark
# cloud_minimalist_black). Written via base64 to avoid the quoting/
# stdin-through-adb breakage that made the plain `cat > file` write silently
# produce no file. run-as works (debug APK). force-stop so the app re-reads
# the pref on next launch.
PKG="@superappPkg@"
if "$ADB" shell pm list packages 2>/dev/null | @gawk@/bin/awk -v p="$PKG" 'index($0,p){f=1} END{exit f?0:1}'; then
  THEME_B64="$(printf '%s' '<?xml version="1.0" encoding="utf-8" standalone="yes" ?><map><string name="theme">@superappLauncherTheme@</string></map>' | base64 -w0)"
  "$ADB" shell "run-as $PKG sh -c 'mkdir -p shared_prefs; echo $THEME_B64 | base64 -d > shared_prefs/launcher_theme_prefs.xml'" >/dev/null 2>&1 || true
  "$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
fi

# land on the (SuperApp) home screen
"$ADB" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
echo "[android-emulator] $avd ready."
