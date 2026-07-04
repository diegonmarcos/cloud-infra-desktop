{
  description = "redroid-apps — reproducible F-Droid/GitHub APK set for Redroid provisioning. Reads apps.lock.json (pinned versionCode + SRI sha256) and materialises every fetched APK into $out/apks/<package>.apk. The lockfile is produced by `../build.sh lock`; this flake never reaches the network for anything but the pinned, hashed URLs, so the output is byte-reproducible.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = nixpkgs.lib.genAttrs systems;
      # Lockfile lives next to this flake (src/apps.lock.json) so flake purity holds.
      lock = builtins.fromJSON (builtins.readFile ./apps.lock.json);
    in {
      packages = forAll (system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          # Only entries that carry a pinned url + sha256 are fetched here.
          # `local`-source apps (e.g. cloud-superapp) are copied in by build.sh, not by nix.
          entries = lib.filter (a: (a ? url) && (a ? sha256)) lock.apps;
          fetched = map (a: {
            name = "${a.package}.apk";
            file = pkgs.fetchurl { url = a.url; hash = a.sha256; };
          }) entries;
          apkSet = pkgs.runCommand "redroid-apks" { } ''
            mkdir -p "$out/apks"
            ${lib.concatMapStringsSep "\n"
                (f: ''cp "${f.file}" "$out/apks/${f.name}"'') fetched}
            cp ${./apps.lock.json} "$out/manifest.json"
          '';
        in {
          apks = apkSet;
          default = apkSet;
        });

      devShells = forAll (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ sqlite jq curl nodejs_22 ];
          };
        });
    };
}
