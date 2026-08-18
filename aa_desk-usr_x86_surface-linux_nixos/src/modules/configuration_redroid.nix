# Redroid host prerequisites (replaces the removed Waydroid host glue).
#
# Redroid (redroid/redroid Docker image) is a headless Android container reached over
# ADB and viewed with scrcpy. The desktop-side app set / launcher layout / theme and the
# `docker run` itself are owned, ON DEMAND, by the data-driven engine at
# ~/git/cloud-unix/da_redroid/build.sh (up|down|provision|scrcpy). This module provides ONLY the
# two things that must exist at the SYSTEM level for that container to work:
#
#   1. binder — Android IPC. Redroid needs binder devices (binder,hwbinder,vndbinder).
#      On the linux-surface mainline kernel these come from CONFIG_ANDROID_BINDERFS
#      (binderfs, built-in) which redroid mounts itself under --privileged. If the kernel
#      instead ships binder as a MODULE (binder_linux), we load it with the device names.
#      boot.kernelModules soft-fails if the module is absent (systemd-modules-load logs and
#      continues) — so this is safe whether binder is built-in (binderfs) or a module.
#      VERIFY on the running kernel: `modinfo binder_linux` / `ls /dev/binderfs`.
#   2. Docker — already enabled + on-demand in docker-daemon.nix (wantedBy=[]). Nothing to
#      add here; the engine `build.sh up` starts the container when you want it.
#
# Deliberately NOT here (the Waydroid post-mortem): no auto-start, no systemd unit that
# respawns Android, no oci-containers definition. The container is created/started only by
# an explicit `build.sh up`, so it can never become a ghost root process surviving GUI close.
{ config, pkgs, lib, ... }:
{
  # Android IPC for the Redroid container. Harmless if binder is built-in (binderfs):
  # systemd-modules-load will note the module is absent and continue; redroid then uses
  # binderfs directly under --privileged.
  boot.kernelModules = [ "binder_linux" ];
  boot.extraModprobeConfig = ''
    options binder_linux devices=binder,hwbinder,vndbinder
  '';

  # scrcpy + android-tools (adb) available system-wide for the launcher / manual use.
  # (The engine also resolves adb/scrcpy from nixpkgs on demand, so this is convenience.)
  environment.systemPackages = with pkgs; [ scrcpy android-tools ];
}
