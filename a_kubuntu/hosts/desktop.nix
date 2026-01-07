# Desktop workstation host configuration
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # GPU monitoring
    nvtopPackages.full

    # Virtualization
    virt-manager
    virt-viewer

    # Gaming (optional, comment out if not needed)
    # steam
    # lutris

    # Desktop utilities
    barrier       # KVM switch software
  ];

  home.sessionVariables = {
    DEVICE = "desktop";
    PROFILE = "auth";
  };

  # Enable syncthing
  services.syncthing.enable = true;
}
