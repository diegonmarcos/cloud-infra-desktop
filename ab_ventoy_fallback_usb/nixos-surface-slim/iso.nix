# NixOS Surface Slim - ISO-specific configuration
# Extends base configuration for live USB boot

{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # ISO IMAGE SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  isoImage = {
    # Volume label for GRUB search
    volumeID = "NIXOS_SURFACE";

    # ISO name
    isoName = "nixos-surface-slim.iso";

    # Compress squashfs with zstd for better size/speed
    squashfsCompression = "zstd -Xcompression-level 19";

    # Include memtest
    includeSystemBuildDependencies = false;

    # Make ISO hybrid (bootable from USB)
    makeEfiBootable = true;
    makeUsbBootable = true;

    # EFI boot
    efiSplashImage = null;

    # GRUB menu entries
    appendToMenuLabel = " (Surface Recovery)";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # BOOT OPTIONS
  # ═══════════════════════════════════════════════════════════════════════════

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    memtest86.enable = false;  # Save space

    # Custom GRUB entries for toram
    extraEntries = ''
      menuentry "NixOS Surface (Load to RAM)" {
        linux /boot/bzImage init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} copytoram
        initrd /boot/initrd
      }
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # LIVE SYSTEM TWEAKS
  # ═══════════════════════════════════════════════════════════════════════════

  # Auto-login for live system
  services.displayManager.autoLogin = {
    enable = true;
    user = "diego";
  };

  # No need for installer
  system.nixos.variant_id = lib.mkDefault "installer";

  # Disable some services for live
  services.udisks2.enable = true;  # USB mounting
  services.gvfs.enable = true;     # File manager mounts

  # Enable copytoram support
  boot.kernelParams = lib.mkAfter [ "copytoram" ];

  # ═══════════════════════════════════════════════════════════════════════════
  # ADDITIONAL LIVE PACKAGES
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # Live system utilities
    ntfs3g
    exfat
    testdisk
    ddrescue
    gparted
  ];
}
