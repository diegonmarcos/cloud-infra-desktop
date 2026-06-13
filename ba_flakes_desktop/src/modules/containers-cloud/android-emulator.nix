# containers-cloud/android-emulator.nix
#
# Declarative Android emulator as a first-class DESKTOP APP on the Surface.
#
# - x86_64 google_apis system image (Android 34), KVM-accelerated (diego is in
#   the `kvm` group via the host's configuration_security.nix; /dev/kvm is
#   world-rw) → near-native speed, genuinely usable as a daily app.
# - The emulator binary + system image come from nix (the SDK closure), so
#   NOTHING is downloaded at runtime — `build.sh switch` realises it once.
# - The AVD itself is runtime state (~/.android/avd), so it can't be pure-nix;
#   it's created idempotently on activation (and again by the launcher as a
#   fallback) — the established "declarative wrapper around a stateful dir"
#   pattern (cf. the host's waydroid-arm-bootstrap).
# - Shows up in the app menu via an xdg desktop entry ("Android Emulator").
#
# This is the GENERAL desktop emulator. The superapp's own arm64 test rig
# (ea_cloud-superapp `build.sh emulator`, devShells.emulator) is separate.
{ config, pkgs, lib, ... }:

let
  # Google's Android SDK is unfree → re-import nixpkgs with the licence
  # accepted (scoped to this module; never a global config change).
  androidPkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = { allowUnfree = true; android_sdk.accept_license = true; };
  };

  comp = androidPkgs.androidenv.composeAndroidPackages {
    toolsVersion         = "26.1.1";   # provides avdmanager
    platformToolsVersion = "35.0.2";   # adb
    buildToolsVersions   = [ "34.0.0" ];
    platformVersions     = [ "34" ];
    includeEmulator      = true;
    includeSystemImages  = true;
    systemImageTypes     = [ "google_apis" ];
    abiVersions          = [ "x86_64" ];
    includeNDK           = false;
  };
  sdk     = comp.androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";
  jdk     = pkgs.jdk17;

  # ── AVD parameters (the declarative config for this emulator) ──────────────
  avdName  = "surface-x86_64";
  sysImage = "system-images;android-34;google_apis;x86_64";
  device   = "pixel_6";
  gpuMode  = "auto";   # let the emulator pick host-GL vs swiftshader

  # avoids the broken-`grep` ambient PATH — match the AVD name with awk.
  avdExists = ''"${sdk}/bin/avdmanager" list avd 2>/dev/null | ${pkgs.gawk}/bin/awk -v n="${avdName}" 'index($0,"Name: "n){f=1} END{exit f?0:1}' '';

  emulatorApp = pkgs.writeShellScriptBin "android-emulator" ''
    set -u
    export ANDROID_SDK_ROOT="${sdkRoot}"
    export ANDROID_HOME="${sdkRoot}"
    export ANDROID_AVD_HOME="$HOME/.android/avd"
    export JAVA_HOME="${jdk}/lib/openjdk"
    export PATH="${jdk}/bin:${sdk}/bin:$PATH"
    mkdir -p "$ANDROID_AVD_HOME"
    if ! ${avdExists}; then
      echo "[android-emulator] first run — creating AVD ${avdName} (${sysImage})…"
      printf 'no\n' | "${sdk}/bin/avdmanager" create avd -n "${avdName}" -k "${sysImage}" --device "${device}" --force
    fi
    exec "${sdk}/bin/emulator" -avd "${avdName}" -gpu ${gpuMode} "$@"
  '';
in
{
  # Only the launcher goes on PATH. The SDK + JDK are pulled into the closure
  # via the launcher's absolute store-path references (so they're retained and
  # runnable) but are NOT added to the profile — that avoids bin collisions
  # with the existing JDK 21 (bin/jar) and android-tools (adb) from other
  # modules. adb/avdmanager/emulator are reachable through the launcher.
  home.packages = [ emulatorApp ];

  # Pre-create the AVD on switch so the app is READY without a first manual
  # launch. Idempotent; never breaks activation (subshell + || true).
  home.activation.androidEmulatorAvd = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
      export ANDROID_SDK_ROOT="${sdkRoot}"
      export ANDROID_HOME="${sdkRoot}"
      export ANDROID_AVD_HOME="$HOME/.android/avd"
      export JAVA_HOME="${jdk}/lib/openjdk"
      export PATH="${jdk}/bin:${sdk}/bin:$PATH"
      mkdir -p "$ANDROID_AVD_HOME"
      if ! ${avdExists}; then
        echo "[android-emulator] creating AVD ${avdName} (${sysImage}) — one-time"
        printf 'no\n' | "${sdk}/bin/avdmanager" create avd -n "${avdName}" -k "${sysImage}" --device "${device}" --force
      fi
    ) || echo "[android-emulator] AVD pre-create skipped/failed; the launcher will create it on first run"
  '';

  # Install the launcher entry into ~/.local/share/applications (XDG_DATA_HOME),
  # NOT the nix profile. KDE live-watches XDG_DATA_HOME/applications (KDirWatch)
  # and auto-rebuilds its ksycoca cache, so the app shows up in Kickoff/KRunner
  # within seconds of `build.sh switch` — no relogin, no manual kbuildsycoca.
  # (home-manager's xdg.desktopEntries lands in the profile share dir, which is
  # in XDG_DATA_DIRS but only scanned on a full rebuild / at login → it would
  # NOT appear mid-session, which is exactly what bit us here.)
  xdg.dataFile."applications/android-emulator.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Android Emulator
    GenericName=Android x86_64 (KVM)
    Comment=Declarative x86_64 Android emulator (Android 14, KVM-accelerated)
    Exec=${emulatorApp}/bin/android-emulator
    Icon=phone
    Terminal=false
    Categories=Development;Emulator;
  '';
}
