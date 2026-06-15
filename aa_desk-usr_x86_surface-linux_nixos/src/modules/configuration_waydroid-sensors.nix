# Host-side system integration for the Waydroid sensors HAL.
#
# This is the ONE thing the HAL needs from the SYSTEM (root) side: the binary
# `waydroid-sensord` discoverable by `which` INSIDE the waydroid-container
# service. waydroid's prop generator (tools/helpers/images.py:make_prop, run by
# the ROOT waydroid-container service) does
#   if which("waydroid-sensord") is None: stub_sensors_hal=1
# With the stub forced, SensorService ignores the real HAL and reports
# "No Sensors" (auto-rotate dead).
#
# CRITICAL: environment.systemPackages alone is NOT enough — the
# waydroid-container.service runs with a RESTRICTED PATH (only coreutils /
# findutils / gnugrep / gnused / systemd, NOT /run/current-system/sw/bin), so
# its shutil.which() never sees a systemPackages binary. We must add the package
# to that service's own `path` (systemd merges `path` lists across modules).
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

let
  # Shared derivation with the subflake's packages.<system>.waydroid-sensord
  # (single source of truth).
  waydroid-sensord = pkgs.callPackage ../../../da_waydroid-sensors/src/nix/package.nix { };
in
{
  # Add to the container service's PATH so its which() probe finds the binary.
  systemd.services.waydroid-container.path = [ waydroid-sensord ];

  # Also expose on the system PATH (manual use: calibrate, status, ad-hoc runs).
  environment.systemPackages = [ waydroid-sensord ];
}
