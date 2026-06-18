# containers-cloud/android-emulator.nix
#
# Declarative, DATA-DRIVEN Android emulator desktop app for the Surface.
#
# One app-menu entry ("Android Emulator") that PROMPTS (kdialog) for one of 8
# profiles — {phone,tablet} × {x86,arm} × {light,full} — then boots an emulator
# with that profile's hardware and PROVISIONS it: installs the matching-ABI
# cloud-superapp APK, sets it as the device HOME launcher, turns on Android
# system dark mode, and pre-seeds the SuperApp's own launcher theme.
#
# x86 profiles = KVM-accelerated CPU + REAL Intel-Xe GPU (ANGLE→Vulkan) for game
# design/dev; arm profiles = TCG software CPU + software GLES for faithful
# arm64-v8a ABI/behaviour testing of the apps.
#
# All config lives in ./android-emulator.json (single source of truth):
#   - profiles are GENERATED = forms × arches × tiers (no hardcoded list)
#   - hardware = raw config.ini keys, merged common→tier→form and written into
#     each AVD's config.ini idempotently on `build.sh switch`
#   - provisioning[] drives the idempotent post-boot adb steps
#
# Two phases:
#   Phase 1 (build-time, declarative): activation creates the 8 AVDs + merges
#           their config.ini from the JSON. Same JSON → same AVDs every switch.
#   Phase 2 (runtime, idempotent):     the launcher boots the chosen profile and
#           runs the provisioner (no-op once already applied).
#
# Prebuilt Google emulator + both system images come from nix (autoPatchelf'd);
# x86 KVM accel works because diego ∈ kvm group (host configuration_security.nix).
# Once the images are nix-store-cached, changing any JSON value (tiers/forms/
# arches/gpu/provisioning) is a FAST switch — no image re-download.
{ config, pkgs, lib, ... }:

let
  cfg = builtins.fromJSON (builtins.readFile ./android-emulator.json);

  # Google's Android SDK is unfree → re-import nixpkgs with the licence accepted
  # (scoped to this module; never a global config change).
  androidPkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = { allowUnfree = true; android_sdk.accept_license = true; };
  };
  comp = androidPkgs.androidenv.composeAndroidPackages {
    toolsVersion         = "26.1.1";   # avdmanager
    platformToolsVersion = "35.0.2";   # adb
    buildToolsVersions   = [ "34.0.0" ];
    platformVersions     = [ "34" ];
    includeEmulator      = true;
    # System images are NO LONGER baked into the nix store — they were the ~8.3G
    # that filled the 80G pool (2026-06-18). They now live on /mnt/shared-lib
    # (p5, ~83G free), installed there by sdkmanager at activation (see `storage`
    # + the p5 setup in the activation script below). nix still provides the
    # emulator + platform/cmdline-tools (autoPatchelf'd → run natively); nix-ld
    # covers any downloaded binary. Trade-off: images download once, online.
    includeSystemImages  = false;
    systemImageTypes     = [ "google_apis" ];
    # Both arches: x86_64 (KVM-fast, games/dev) + arm64-v8a (faithful ARM test,
    # CPU software-emulated). Each pulls its Android-34 google_apis image.
    abiVersions          = [ "x86_64" "arm64-v8a" ];
    includeNDK           = false;
  };
  sdk     = comp.androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";
  jdk     = pkgs.jdk17;
  kdialog = pkgs.kdePackages.kdialog;

  # Heavy SDK data (system images + AVDs) lives on p5, not the nix pool.
  # p5Sdk is the diego-owned dir provisioned by the NixOS host tmpfiles rule.
  storage = cfg.storage;
  p5Sdk   = storage.sdk_root;
  p5Avd   = storage.avd_home;
  # System-image package ids are derived from the (data-driven) arches — no
  # second hardcoded list (DRY).
  imageIdsStr = lib.concatStringsSep " " (lib.unique (lib.mapAttrsToList (_: a: a.image) cfg.arches));

  cap = s: (lib.toUpper (builtins.substring 0 1 s)) + (builtins.substring 1 (builtins.stringLength s) s);

  # profiles = forms × arches × tiers → 8: {Phone,Tablet}×{x86,arm}×{full,light}.
  # Each carries its merged hardware (common → tier → form; form's screen keys
  # win) + the arch's abi.type, its system image, and a "Phone_x86_full" label.
  profiles = lib.concatMap (fname:
    lib.concatMap (aname:
      map (tname:
        let
          fhw  = cfg.forms.${fname};
          thw  = cfg.tiers.${tname};
          arch = cfg.arches.${aname};
        in {
          id    = "${fname}-${aname}-${tname}";
          avd   = "superapp-${fname}-${aname}-${tname}";
          label = "${cap fname}_${arch.label}_${tname}";
          image = arch.image;
          abi   = arch.abi;
          gpu   = arch.gpu_mode;          # per-arch GPU mode (see android-emulator.json)
          hw    = cfg.common_hw // thw // fhw // { "abi.type" = arch.abi; "hw.gpu.mode" = arch.gpu_mode; };
        }
      ) (lib.attrNames cfg.tiers)
    ) (lib.attrNames cfg.arches)
  ) (lib.attrNames cfg.forms);

  # "key=value key=value …" for a profile's hardware (values are space-free).
  hwPairs = p: lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${v}") p.hw);

  # kdialog --menu tag/description pairs, e.g.  phone-x86-full "Phone_x86_full (6144M/6c)"
  menuArgs = lib.concatStringsSep " " (map (p:
    ''${p.id} "${p.label} (${p.hw."hw.ramSize"}/${p.hw."hw.cpu.ncore"}c)"'') profiles);

  # case body mapping the chosen profile id → its GPU mode + ABI (data-driven;
  # x86 → angle_indirect = hardware GLES via Intel Vulkan, arm → swiftshader_indirect).
  profCase = lib.concatMapStringsSep "\n      " (p:
    ''${p.id}) gpu="${p.gpu}"; abi="${p.abi}" ;;'') profiles;

  prov = cfg.provisioning;

  # Per-app install block (idempotent). $HOME inside the JSON apk path expands at
  # runtime; the `{abi}` token is replaced with the booted profile's ABI ($abi,
  # set by the launcher) so an arm profile installs the arm64 APK and x86 the
  # x86_64 one — a wrong-ABI install would defeat the faithful-ARM-test goal.
  installApps = lib.concatMapStringsSep "\n" (a: ''
    if ! "$ADB" shell pm list packages 2>/dev/null | ${pkgs.gawk}/bin/awk -v p="${a.pkg}" 'index($0,p){f=1} END{exit f?0:1}'; then
      APK="${a.apk}"; APK="''${APK//'{abi}'/$abi}"
      if [ -f "$APK" ]; then
        echo "[provision] installing ${a.pkg} ($abi)…"; "$ADB" install -r "$APK" || true
      else
        kdialog --error "APK not found:\n$APK\n\nBuild it once:\n  cd ~/git/unix/ea_cloud-superapp && SUPERAPP_VARIANT=$abi ./build.sh build" 2>/dev/null || true
      fi
    fi
  '') prov.apps;

  # System settings (data-driven) — e.g. disable window/transition animations.
  # Harmless on hardware (x86) and a real help on the software-GLES arm guests.
  applySettings = lib.optionalString (prov ? settings) (lib.concatMapStringsSep "\n" (s:
    ''"$ADB" shell settings put ${s.ns} ${s.key} ${s.value} >/dev/null 2>&1 || true'') prov.settings);

  # ── Launcher: profile chooser → boot → wait → provision ─────────────────────
  emulatorApp = pkgs.writeShellScriptBin "android-emulator" ''
    set -u
    # SDK_ROOT = the p5 composite SDK (nix components symlinked in by the
    # activation + the bulky system images on p5); AVDs also on p5. The
    # emulator/adb binaries are still nix (${sdk}/bin); the emulator resolves the
    # AVD's image.sysdir against ANDROID_SDK_ROOT → the p5 image.
    export ANDROID_SDK_ROOT="${p5Sdk}"
    export ANDROID_HOME="${p5Sdk}"
    export ANDROID_AVD_HOME="${p5Avd}"
    export JAVA_HOME="${jdk}/lib/openjdk"
    export PATH="${jdk}/bin:${sdk}/bin:${kdialog}/bin:$PATH"
    # NixOS host-GPU acceleration: the emulator's bundled GL/Vulkan can't find
    # the system driver on its own, so -gpu host/auto fell back to slow software
    # GL (felt like "thrashing"). Point it at the NixOS runtime driver dir + host
    # Vulkan ICDs so `auto` uses real Intel hardware accel; it still falls back to
    # software if unavailable, so the window always opens. Data-driven: discovers
    # whatever ICDs the host declares (no hardcoded GPU vendor).
    export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    VK_ICD_FILENAMES=""
    for _icd in /run/opengl-driver/share/vulkan/icd.d/*.json; do
      [ -e "$_icd" ] && VK_ICD_FILENAMES="$VK_ICD_FILENAMES''${VK_ICD_FILENAMES:+:}$_icd"
    done
    export VK_ICD_FILENAMES
    ADB="${sdk}/bin/adb"
    EMU="${sdk}/bin/emulator"

    # 1. profile chooser
    sel="$(kdialog --title "Android Emulator" --menu "Choose a profile to boot:" ${menuArgs})" || exit 0
    avd="superapp-$sel"
    if [ ! -d "$ANDROID_AVD_HOME/$avd.avd" ]; then
      kdialog --error "AVD '$avd' not found. Run:\n  cd ~/git/unix/ba_flakes_desktop && ./build.sh switch surface" 2>/dev/null || true
      exit 1
    fi

    # resolve the chosen profile's GPU mode + ABI (data-driven, per-arch)
    gpu="swiftshader_indirect"; abi="x86_64"
    case "$sel" in
      ${profCase}
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
    ${installApps}

    ${lib.optionalString prov.system_dark ''
    "$ADB" shell cmd uimode night yes >/dev/null 2>&1 || true
    ''}

    # data-driven system settings (e.g. disable animations → far less work for
    # the software-GLES renderer on this host).
    ${applySettings}

    # set the SuperApp as the device HOME launcher
    "$ADB" shell cmd package set-home-activity "${prov.home_launcher}" >/dev/null 2>&1 || true

    # pre-seed the SuperApp's own launcher theme (data-driven; the dark
    # cloud_minimalist_black). Written via base64 to avoid the quoting/
    # stdin-through-adb breakage that made the plain `cat > file` write silently
    # produce no file. run-as works (debug APK). force-stop so the app re-reads
    # the pref on next launch.
    PKG="${prov.superapp_pkg}"
    if "$ADB" shell pm list packages 2>/dev/null | ${pkgs.gawk}/bin/awk -v p="$PKG" 'index($0,p){f=1} END{exit f?0:1}'; then
      THEME_B64="$(printf '%s' '<?xml version="1.0" encoding="utf-8" standalone="yes" ?><map><string name="theme">${prov.superapp_launcher_theme}</string></map>' | base64 -w0)"
      "$ADB" shell "run-as $PKG sh -c 'mkdir -p shared_prefs; echo $THEME_B64 | base64 -d > shared_prefs/launcher_theme_prefs.xml'" >/dev/null 2>&1 || true
      "$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
    fi

    # land on the (SuperApp) home screen
    "$ADB" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    echo "[android-emulator] $avd ready."
  '';
in
{
  # Only the launcher goes on PATH; SDK/JDK/kdialog are retained via the
  # wrapper's store-path refs (off-profile → no bin collisions with JDK 21 etc.).
  home.packages = [ emulatorApp ];

  # Phase 1 — create the 4 AVDs + write their config.ini from the JSON, on every
  # switch. Idempotent; subshell + || true so it never breaks activation.
  home.activation.androidEmulatorProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
      # ── p5 storage gate ─────────────────────────────────────────────────
      # Heavy SDK data lives on /mnt/shared-lib (p5). If the diego-owned dir
      # isn't there yet (NixOS host tmpfiles rule not applied, or pool
      # unmounted), skip gracefully — NEVER break activation.
      if [ ! -d "${p5Sdk}" ] || [ ! -w "${p5Sdk}" ]; then
        echo "[android-emulator] ${p5Sdk} not writable — apply the NixOS host (tmpfiles) first, then re-switch. Skipping AVD setup."
        exit 0
      fi
      export ANDROID_SDK_ROOT="${p5Sdk}"
      export ANDROID_HOME="${p5Sdk}"
      export ANDROID_AVD_HOME="${p5Avd}"
      export JAVA_HOME="${jdk}/lib/openjdk"
      export PATH="${jdk}/bin:${sdk}/bin:$PATH"
      mkdir -p "$ANDROID_AVD_HOME"

      # Compose the p5 SDK: symlink the nix-provided components (read-only,
      # autoPatchelf'd) into the writable p5 root so avdmanager/emulator see a
      # complete SDK, while the bulky system-images live on p5 (writable).
      for _c in emulator platform-tools cmdline-tools tools licenses platforms build-tools; do
        [ -e "${sdkRoot}/$_c" ] && ln -sfn "${sdkRoot}/$_c" "${p5Sdk}/$_c"
      done

      # Install the declared system images onto p5 (idempotent — sdkmanager skips
      # already-present packages; network only on first run / a new image).
      _need=0
      for _img in ${imageIdsStr}; do
        _rel=$(printf '%s' "$_img" | ${pkgs.gnused}/bin/sed 's/^system-images;//; s/;/\//g')
        [ -d "${p5Sdk}/system-images/$_rel" ] || _need=1
      done
      if [ "$_need" = "1" ]; then
        echo "[android-emulator] installing system images onto p5 (one-time, needs network)…"
        yes | "${sdk}/bin/sdkmanager" --sdk_root="${p5Sdk}" --licenses >/dev/null 2>&1 || true
        "${sdk}/bin/sdkmanager" --sdk_root="${p5Sdk}" ${imageIdsStr} 2>&1 | tail -3 \
          || echo "[android-emulator] sdkmanager failed (offline?) — AVDs will be created on the next online switch."
      fi

      avd_exists() { "${sdk}/bin/avdmanager" list avd 2>/dev/null | ${pkgs.gawk}/bin/awk -v n="$1" 'index($0,"Name: "n){f=1} END{exit f?0:1}'; }

      # set-or-replace declared keys in an AVD config.ini, preserving everything
      # else (image.sysdir.1, device hash, etc.). Idempotent.
      merge_ini() {
        local f="$1"; shift
        [ -f "$f" ] || return 0
        local tmp; tmp="$(mktemp)"
        ${pkgs.gawk}/bin/awk -v assigns="$*" '
          BEGIN { n=split(assigns,a," "); for(i=1;i<=n;i++){ e=index(a[i],"="); ov[substr(a[i],1,e-1)]=substr(a[i],e+1); } }
          { key=$0; sub(/ *=.*/,"",key);
            if(key in ov){ print key " = " ov[key]; seen[key]=1 } else print }
          END { for(k in ov) if(!(k in seen)) print k " = " ov[k] }
        ' "$f" > "$tmp" && mv "$tmp" "$f"
      }

      ensure_profile() {
        local avd="$1" image="$2"; shift 2
        if ! avd_exists "$avd"; then
          echo "[android-emulator] creating AVD $avd ($image)"
          printf 'no\n' | "${sdk}/bin/avdmanager" create avd -n "$avd" -k "$image" --force || return 0
        fi
        merge_ini "$ANDROID_AVD_HOME/$avd.avd/config.ini" "$@"
      }

      ${lib.concatMapStringsSep "\n      " (p: ''ensure_profile ${p.avd} "${p.image}" ${hwPairs p}'') profiles}

      # retire superseded AVDs (old single-profile + the pre-arch 4-profile names)
      for _old in surface-x86_64 superapp-phone-light superapp-phone-full superapp-tablet-light superapp-tablet-full; do
        rm -rf "$ANDROID_AVD_HOME/$_old.avd" "$ANDROID_AVD_HOME/$_old.ini" 2>/dev/null || true
      done
    ) || echo "[android-emulator] profile pre-create skipped/failed; run ./build.sh switch from a working state"
  '';

  # Single app-menu entry → ~/.local/share/applications (KDE-live-watched, the
  # fix from a07e1dde). Exec is the chooser launcher.
  xdg.dataFile."applications/android-emulator.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Android Emulator
    GenericName=Android x86_64 (KVM) — profile chooser
    Comment=Boot a predefined Android profile (phone/tablet · light/full) with the Cloud SuperApp as launcher
    Exec=${emulatorApp}/bin/android-emulator
    Icon=phone
    Terminal=false
    Categories=Development;Emulator;
  '';
}
