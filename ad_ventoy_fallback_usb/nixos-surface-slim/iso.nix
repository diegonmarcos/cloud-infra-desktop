# NixOS Surface Slim - ISO-specific configuration
# For live USB boot via Ventoy

{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # ISO IMAGE SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  isoImage = {
    # Volume label (for GRUB search and Ventoy)
    volumeID = "NIXOS_SURFACE";

    # Output filename
    isoName = "nixos-surface-slim.iso";

    # Maximum compression for smallest size
    squashfsCompression = "zstd -Xcompression-level 19";

    # Don't include build dependencies (saves ~500MB+)
    includeSystemBuildDependencies = false;

    # Make bootable from USB
    makeEfiBootable = true;
    makeUsbBootable = true;

    # No splash image (slimmer)
    efiSplashImage = null;

    # GRUB menu label
    appendToMenuLabel = " (Surface Slim)";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # BOOT LOADER
  # ═══════════════════════════════════════════════════════════════════════════

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    memtest86.enable = false;  # Save space
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # LIVE SYSTEM TWEAKS
  # ═══════════════════════════════════════════════════════════════════════════

  # Keep console auto-login from main config
  # No display manager auto-login needed

  # USB/disk mounting support
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  # copytoram support (Ventoy handles this via its own menu)
  boot.kernelParams = lib.mkAfter [ "copytoram" ];

  # ═══════════════════════════════════════════════════════════════════════════
  # ADDITIONAL LIVE PACKAGES
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # Recovery tools
    testdisk
    ddrescue
  ];
}
