{
  description = "waydroid-sensors — host-side Android sensors HAL (HIDL @1.0 ISensors over libgbinder) for Waydroid, fed by the Linux IIO accelerometer. Reproducible CMake build against nixpkgs libgbinder/libglibutil/glib.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAll (system:
        let
          pkgs = import nixpkgs { inherit system; };
          # Single source of truth: the same callPackage-able derivation the
          # surface host flake path-imports into environment.systemPackages
          # (see ./nix/package.nix for why the binary must be on PATH).
          waydroid-sensord = pkgs.callPackage ./nix/package.nix { };
        in {
          inherit waydroid-sensord;
          default = waydroid-sensord;
        });

      devShells = forAll (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.cmake pkgs.pkg-config pkgs.glib pkgs.libglibutil pkgs.libgbinder pkgs.nodejs_22 ];
          };
        });
    };
}
