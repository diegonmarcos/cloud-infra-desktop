# Surface Pro 8 host configuration
{ config, pkgs, lib, ... }:

{
  # Surface-specific packages
  home.packages = with pkgs; [
    # Power management
    powertop
    tlp

    # Touch/stylus (if available in user space)
    # libwacom packages are usually system-level

    # Monitoring
    lm_sensors
  ];

  # Surface Pro 8 specific environment
  home.sessionVariables = {
    DEVICE = "surface";
    # Profile managed by dual-profile system
    PROFILE = "auth";
  };

  # Enable syncthing service
  services.syncthing = {
    enable = true;
    tray.enable = false;  # No tray in standalone mode
  };
}
