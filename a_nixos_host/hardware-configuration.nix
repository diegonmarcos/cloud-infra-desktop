# Hardware configuration for Surface Pro 8
# NixOS with Full Impermanence - tmpfs root

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # BOOT CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  boot = {
    # LUKS configuration
    initrd = {
      availableKernelModules = [
        "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod"
        # Surface-specific
        "surface_aggregator" "surface_aggregator_registry"
        "surface_hid" "surface_hid_core"
        "8250_dw" "pinctrl_tigerlake"
        # BTRFS
        "btrfs"
      ];
      kernelModules = [ "dm-snapshot" ];

      luks.devices."pool" = {
        device = "/dev/disk/by-uuid/3c75c6db-4d7c-4570-81f1-02d168781aac";
        preLVM = true;
        allowDiscards = true;
      };
    };

    kernelModules = [ "kvm-intel" ];
    extraModulePackages = [ ];

    # Disable systemd-boot (we use GRUB from Ubuntu/independent)
    loader.grub.enable = false;
    loader.systemd-boot.enable = false;
    loader.efi.canTouchEfiVariables = false;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # FILESYSTEM MOUNTS - IMPERMANENCE
  # ═══════════════════════════════════════════════════════════════════════════

  # Root is tmpfs - wiped on every boot
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "defaults" "size=2G" "mode=755" ];
  };

  # /nix - persistent Nix store (inside @root-nixos)
  fileSystems."/nix" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@root-nixos/nix" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  # /persist - persistent state (inside @root-nixos)
  fileSystems."/persist" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@root-nixos/persist" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  # /home - user home directory
  fileSystems."/home" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@home-nixos" "compress=zstd" "noatime" ];
  };

  # /mnt/shared - common storage for both OSes
  fileSystems."/mnt/shared" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@shared" "compress=zstd" "noatime" ];
  };

  # /boot - shared boot partition (ext4, unencrypted)
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0eaf7961-48c5-4b55-8a8f-04cd0b71de07";
    fsType = "ext4";
  };

  # /boot/efi - EFI system partition
  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-uuid/2CE0-6722";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  # Waydroid storage
  fileSystems."/var/lib/waydroid" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@android" "compress=zstd" "noatime" ];
  };

  # No swap
  swapDevices = [ ];

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE
  # ═══════════════════════════════════════════════════════════════════════════

  # Surface Pro 8 has Intel Tiger Lake
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware for WiFi, etc.
  hardware.enableRedistributableFirmware = true;

  # Power management
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

  # Platform
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
