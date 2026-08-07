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
    includeSystemImages  = true;
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
  # Still used by the activation script below (data source, not shell-text
  # generation — the activation loop reads the equivalent JSON at runtime).
  hwPairs = p: lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${v}") p.hw);

  prov = cfg.provisioning;

  # Runtime JSON (single source of truth stays android-emulator.json; this is
  # just the computed `profiles` cross-product + `prov`, serialised so the
  # launcher and the activation script can both read it at RUNTIME via jq
  # instead of Nix unrolling per-profile/per-app/per-setting shell stanzas at
  # eval time). Mirrors the shared-symlink.sh / kernel-closure-backup.sh
  # builtins.toJSON-of-a-computed-list pattern.
  runtimeJson = builtins.toJSON { inherit profiles; provisioning = prov; };

  # ── Launcher: profile chooser → boot → wait → provision ─────────────────────
  # Body extracted to ./android-emulator.sh; all per-profile/per-app/
  # per-setting data now comes from the runtime JSON via jq, not Nix-side
  # map/concatMapStringsSep. Binary paths arrive via runtimeInputs (never
  # ${pkgs.foo} inside the .sh); ANDROID_SDK_ROOT/HOME/JAVA_HOME via runtimeEnv.
  emulatorApp = pkgs.writeShellApplication {
    name = "android-emulator";
    runtimeInputs = [ sdk jdk kdialog pkgs.jq pkgs.gawk pkgs.coreutils ];
    runtimeEnv = {
      ANDROID_SDK_ROOT = sdkRoot;
      ANDROID_HOME = sdkRoot;
      JAVA_HOME = "${jdk}/lib/openjdk";
    };
    text = builtins.readFile ./android-emulator.sh;
  };
in
{
  # Only the launcher goes on PATH; SDK/JDK/kdialog are retained via the
  # wrapper's store-path refs (off-profile → no bin collisions with JDK 21 etc.).
  home.packages = [ emulatorApp ];

  # Runtime JSON deploy (Home Manager: xdg.configFile) — single source both
  # the launcher (via runtimeEnv-resolved jq) and the activation script below
  # read at runtime, generated from the Nix-computed `profiles` + `prov`.
  xdg.configFile."cloud-data/android-emulator.json".text = runtimeJson;

  # Phase 1 — create the 8 AVDs + write their config.ini from the JSON, on every
  # switch. Idempotent; subshell + || true so it never breaks activation.
  # entryAfter "linkGeneration" (not just "writeBoundary") so the JSON above
  # is already symlinked into place before this reads it.
  home.activation.androidEmulatorProfiles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
      export ANDROID_SDK_ROOT="${sdkRoot}"
      export ANDROID_HOME="${sdkRoot}"
      export ANDROID_AVD_HOME="$HOME/.android/avd"
      export JAVA_HOME="${jdk}/lib/openjdk"
      export PATH="${jdk}/bin:${sdk}/bin:$PATH"
      mkdir -p "$ANDROID_AVD_HOME"

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

      # RUNTIME loop over the same `profiles` list, now read from the JSON
      # deployed by xdg.configFile above (was: lib.concatMapStringsSep
      # unrolling one `ensure_profile ...` call per profile at Nix eval time).
      CONFIG_JSON="$HOME/.config/cloud-data/android-emulator.json"
      if [ -r "$CONFIG_JSON" ]; then
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          avd="$(printf '%s' "$p" | ${pkgs.jq}/bin/jq -r '.avd')"
          image="$(printf '%s' "$p" | ${pkgs.jq}/bin/jq -r '.image')"
          hwpairs="$(printf '%s' "$p" | ${pkgs.jq}/bin/jq -r '.hw | to_entries | map("\(.key)=\(.value)") | join(" ")')"
          # word-splitting hwpairs into ensure_profile's "$@" is intentional
          # (space-joined key=value list, same shape the Nix-generated call
          # used to pass literally).
          # shellcheck disable=SC2086
          ensure_profile "$avd" "$image" $hwpairs
        done < <(${pkgs.jq}/bin/jq -c '.profiles[]' "$CONFIG_JSON")
      else
        echo "[android-emulator] $CONFIG_JSON missing; skipping profile pre-create"
      fi

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
