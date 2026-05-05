{
  description = "Pixel + GrapheneOS provisioner — fetches ROM image + APK set into dist/.";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs      = import nixpkgs { inherit system; };
        buildJson = builtins.fromJSON (builtins.readFile ../build.json);
        apksJson  = builtins.fromJSON (builtins.readFile ../data/apks.json);
        device    = buildJson.device;

        # GrapheneOS factory image — pin sha256 via `nix-prefetch-url`.
        factory = pkgs.fetchurl {
          url    = "https://releases.grapheneos.org/${device.codename}-factory-${device.rom_pinned_build}.zip";
          sha256 = ""; # FILL — block on first build, re-run with the printed hash.
        };

        # Per-source fetcher dispatch (sketch — populate when wiring real APK URLs/hashes).
        fetchApk = a: pkgs.runCommand "${a.package}.apk" { } ''
          mkdir -p $out
          # TODO: implement source-specific fetch:
          #   fdroid              → fetchurl from f-droid.org/repo/${a.package}_<v>.apk
          #   izzyondroid         → fetchurl from apt.izzysoft.de/fdroid/repo
          #   graphene-app-store  → fetchurl from apps.grapheneos.org
          #   play                → cannot fetch hermetically; left as runtime aurora pull
          touch $out/${a.package}.apk
        '';

        apksDrv = pkgs.symlinkJoin {
          name  = "apks";
          paths = map fetchApk (builtins.filter (a: a.source != "play") apksJson.apks);
        };
      in {
        packages.factory = factory;
        packages.apks    = apksDrv;
        packages.default = pkgs.symlinkJoin {
          name  = "phone-dist";
          paths = [ factory apksDrv ];
        };
      });
}
