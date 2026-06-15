# Host-side system integration for the Waydroid sensors HAL.
#
# This is the ONE thing the HAL needs from the SYSTEM (root) side: the binary
# `waydroid-sensord` on the system PATH. waydroid's prop generator
# (tools/helpers/images.py:make_prop, run by the ROOT waydroid-container
# service) does `if which("waydroid-sensord") is None: stub_sensors_hal=1`.
# With the stub forced, SensorService ignores the real HAL and reports
# "No Sensors" (auto-rotate dead). Putting the package in systemPackages
# (/run/current-system/sw/bin) makes that `which` succeed → no stub.
#
# The DAEMON itself is run by the home-manager user service
# (ba_flakes_desktop/src/modules/containers-cloud/waydroid-sensors.nix) from the
# pre-built dist/ artifact — same split as fido2-vault-broker (system module =
# system integration; user-session daemon = home-manager). So this file does
# NOT start a second daemon; it only satisfies waydroid's PATH probe.
#
# Composed by PLAIN PATH IMPORT (mirrors configuration_fido2-vault-broker.nix):
# nix 2.24 cannot lock relative-path flake inputs — see the NOTE in flake.nix.
{ pkgs, ... }:

{
  environment.systemPackages = [
    # Shared derivation with the subflake's packages.<system>.waydroid-sensord
    # (single source of truth).
    (pkgs.callPackage ../../../da_waydroid-sensors/src/nix/package.nix { })
  ];
}
