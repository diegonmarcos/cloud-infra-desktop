{
  description = "Cloud-Comms — Nix devShell wrapping the Android Gradle build for the hub APK + the materialized forks (gradle + AGP + Android SDK + JDK 17 + Node for the React-Native fork). All toolchain pinned; same input → same APK.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        # Toolchain pinned in one place. Mirrored in build.json::toolchain —
        # keep in sync. Same SDK/build-tools/NDK combo as ea_cloud-superapp so
        # the two Android projects share one reproducible toolchain.
        androidEnv = pkgs.androidenv.composeAndroidPackages {
          toolsVersion         = "26.1.1";
          platformToolsVersion = "35.0.2";
          buildToolsVersions   = [ "35.0.0" "34.0.0" ];
          platformVersions     = [ "35" "34" "26" ];
          # Element X (matrix fork) ships Rust matrix-sdk .so via prebuilt AARs
          # but the hub itself is pure-JVM. NDK kept available for the forks
          # that bundle native libs (Element X bindings, any RN native modules).
          includeNDK           = true;
          ndkVersions          = [ "26.1.10909125" ];
          cmakeVersions        = [ "3.22.1" ];
          includeEmulator      = false;
          includeSystemImages  = false;
        };

        androidSdk = androidEnv.androidsdk;
      in {
        devShells.default = pkgs.mkShell {
          name = "cloud-comms-devshell";
          buildInputs = with pkgs; [
            jdk17
            gradle_8
            kotlin
            androidSdk
            android-tools     # adb, fastboot
            # Node toolchain for the Mattermost React-Native fork (Metro
            # bundler + JS deps). The hub + native forks don't need it, but
            # `./build.sh build-fork chat` does.
            nodejs_20
            yarn
            jq                # build.sh reads build.json + validates contract
            check-jsonschema  # `./build.sh verify-contract` schema validation
            oras              # OCI artifact push to ghcr (release.ghcr)
            gh                # GitHub Release / gh run list
            git               # materialize-fork: clone + checkout pin + apply
          ];

          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          JAVA_HOME = "${pkgs.jdk17}/lib/openjdk";
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/libexec/android-sdk/build-tools/35.0.0/aapt2";

          shellHook = ''
            echo "Cloud-Comms devShell"
            echo "  java=$(java -version 2>&1 | head -1)"
            echo "  gradle=$(gradle --version | grep '^Gradle' || true)"
            echo "  node=$(node --version 2>/dev/null || echo 'n/a')"
            echo "  android-sdk=$ANDROID_HOME"
            echo "Commands: ./build.sh {build|verify-contract|materialize-fork <k>|build-fork <k>|clean|shell|ship}"
          '';
        };

        # Hermetic APK build needs a checked-in gradle wrapper + dependency
        # lockfile. For now the devShell + ./build.sh build is the path,
        # matching ea_cloud-superapp.
        packages.default = pkgs.runCommandLocal "cloud-comms-stub" {} ''
          mkdir -p $out
          echo "TODO: hermetic APK build needs gradle wrapper checked in + dependency lockfile" > $out/README
        '';
      });
}
