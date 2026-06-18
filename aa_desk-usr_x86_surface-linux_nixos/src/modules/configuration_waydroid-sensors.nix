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
# The DAEMON is launched by waydroid-container ITSELF: once `waydroid-sensord` is
# on the container service's PATH, waydroid's hardware_manager starts it on each
# session (verified: the root `waydroid-sensord /dev/hwbinder` process is a CHILD
# of `.waydroid.py -w container start`). So this module is the SOLE launcher — the
# former home-manager user service (ba_flakes_desktop/.../waydroid-sensors.nix) was
# a SECOND daemon racing on /dev/hwbinder and was removed (2026-06-18). waydroid
# launches it with NO environment, so its config comes from /etc (environment.etc
# below), and boot-safety lives INSIDE the daemon (bounded poll() in SensorFW.cpp),
# not an external supervisor.
#
# Composed by PLAIN PATH IMPORT (mirrors configuration_fido2-vault-broker.nix):
# nix 2.24 cannot lock relative-path flake inputs — see the NOTE in flake.nix.
{ pkgs, ... }:

let
  # Shared derivation with the subflake's packages.<system>.waydroid-sensord
  # (single source of truth). passthru.confFile = build.json-rendered daemon conf.
  waydroid-sensord = pkgs.callPackage ../../../da_waydroid-sensors/src/nix/package.nix { };
in
{
  # Add to the container service's PATH so its which() probe finds the binary AND
  # so the daemon waydroid spawns inherits the right runtime deps.
  systemd.services.waydroid-container.path = [ waydroid-sensord ];

  # Also expose on the system PATH (manual use: calibrate, status, ad-hoc runs).
  environment.systemPackages = [ waydroid-sensord ];

  # Data-driven config for the daemon waydroid launches with NO environment. Path
  # MUST match build.json runtime.conf_install_path + the fallback in SensorFW.cpp.
  environment.etc."waydroid-sensors/waydroid-sensors.conf".source = waydroid-sensord.confFile;
}
