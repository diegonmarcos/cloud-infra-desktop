# waydroid-sensord package — callPackage-able, single source of truth.
#
# Consumed two ways (mirrors da_fido2-vault-broker/src/nix/package.nix):
#   1. The subflake's own `packages.<system>.waydroid-sensord` (flake.nix:
#      pkgs.callPackage ./nix/package.nix { }).
#   2. The surface host flake by PLAIN PATH IMPORT
#      (aa_desk-usr_x86_surface-linux_nixos/src/modules/
#       configuration_waydroid-sensors.nix: pkgs.callPackage ...), which puts
#      the binary on the SYSTEM PATH.
#
# WHY the host needs it on PATH: waydroid (tools/helpers/images.py:make_prop,
# run by the ROOT waydroid-container service) decides whether to force the empty
# stub sensors HAL purely by `which("waydroid-sensord")` — if the binary is NOT
# on PATH it appends `waydroid.stub_sensors_hal=1`, which makes SensorService
# ignore the real HAL and report "No Sensors". Putting this package in
# environment.systemPackages (/run/current-system/sw/bin) makes that `which`
# succeed → no stub → the running daemon (registered on /dev/hwbinder) is used.
#
# WHY path import, not a flake input: nix 2.24 cannot lock relative-path flake
# inputs inside a git flake (see the NOTE in the host flake.nix). Revisit when
# nix >= 2.26 ships native relative-path flake inputs.
{
  lib,
  stdenv,
  cmake,
  pkg-config,
  glib,
  libglibutil,
  libgbinder,
}:

stdenv.mkDerivation {
  pname = "waydroid-sensord";
  version = "0.1.0";
  src = ../code;
  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ glib libglibutil libgbinder ];
  meta = {
    description = "IIO-backed Android sensors HAL for Waydroid (HIDL @1.0 ISensors over libgbinder)";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "waydroid-sensord";
  };
}
