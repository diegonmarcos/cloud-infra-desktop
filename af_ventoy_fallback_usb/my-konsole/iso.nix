# my-konsole - ISO-specific configuration
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
    volumeID = "MY_KONSOLE";

    # Output filename
    isoName = "my-konsole.iso";

    # Maximum compression for smallest size
    squashfsCompression = "zstd -Xcompression-level 19";

    # Don't include build dependencies (saves ~500MB+)
    includeSystemBuildDependencies = false;

    # Make bootable from USB
    makeEfiBootable = true;
    makeUsbBootable = true;

    # NOTE: do NOT set efiSplashImage = null. nixpkgs iso-image.nix adds the
    # efiSplashImage → /EFI/BOOT/efi-background.png entry UNCONDITIONALLY (unlike
    # grubTheme, which is null-guarded), so null yields an empty pathlist source
    # → xorriso "Will not graft-in the whole local filesystem by path '/'" →
    # build aborts. Leave it at the default (a small stock PNG; negligible size).

    # GRUB menu label
    appendToMenuLabel = " (my-konsole)";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # BOOT LOADER
  # ═══════════════════════════════════════════════════════════════════════════
  # NOTE: do NOT set boot.loader.grub.enable here. iso-image.nix owns the ISO's
  # EFI boot (via isoImage.makeEfiBootable above) and pins the *installed
  # system* bootloader to disabled. Re-enabling grub is both a conflicting
  # definition and semantically wrong for a live ISO (that option installs a
  # bootloader onto a target disk).

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
