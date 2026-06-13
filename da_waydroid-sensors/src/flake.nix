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
          waydroid-sensord = pkgs.stdenv.mkDerivation {
            pname = "waydroid-sensord";
            version = "0.1.0";
            src = ./code;
            nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
            buildInputs = [ pkgs.glib pkgs.libglibutil pkgs.libgbinder ];
            meta = {
              description = "IIO-backed Android sensors HAL for Waydroid";
              license = pkgs.lib.licenses.gpl3Only;
              platforms = systems;
            };
          };
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
