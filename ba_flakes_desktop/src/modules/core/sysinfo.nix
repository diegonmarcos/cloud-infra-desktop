# core/sysinfo.nix — system inspection / process management
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    # Process management
    procps           # ps, top, kill, vmstat, free
    psmisc           # killall, pstree, peekfd

    # System info
    neofetch
    lshw
    pciutils
    usbutils

    # Live monitors
    htop
    iotop
    sysstat          # iostat, mpstat, pidstat, sar
  ];
}
