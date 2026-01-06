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
        "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "uas"
        # BTRFS
        "btrfs"
        # VFAT for USB keyfile - MUST be in availableKernelModules to be included in initrd
        "vfat" "fat" "nls_cp437" "nls_iso8859_1" "nls_utf8"
      ];
      # CRITICAL: Force-load these modules BEFORE LUKS prompt
      kernelModules = [
        "dm-snapshot"
        # FAT/VFAT for USB keyfile - MUST load early for preOpenCommands
        "vfat" "fat" "nls_cp437" "nls_iso8859-1" "nls_utf8"
        # Surface Aggregator Module (SAM) - controls Type Cover
        "surface_aggregator"
        "surface_aggregator_registry"
        "surface_aggregator_hub"
        # Surface HID drivers for keyboard/touchpad
        "surface_hid"
        "surface_hid_core"
        # Intel LPSS (Low Power Subsystem) - required for SAM communication
        "intel_lpss"
        "intel_lpss_pci"
        # Serial driver for SAM
        "8250_dw"
        # GPIO controller for Tiger Lake
        "pinctrl_tigerlake"
        # HID for touch/multitouch input
        "hid_multitouch"
        "hid_generic"
        # FALLBACK: Surface touchscreen modules (for on-screen keyboard)
        "surface_hid"
        "i2c_hid"
        "i2c_hid_acpi"
        "hid_multitouch"
        # Intel touch controller
        "intel_ish_ipc"
        "intel_ishtp"
        "intel_ishtp_hid"
      ];

      # DISABLED: systemd-initrd breaks tmpfs root + impermanence
      # Also breaks preOpenCommands/postOpenCommands for USB keyfile
      # systemd.enable = true;

      # Support FAT filesystem in initrd (for USB keyfile mounting)
      supportedFilesystems = [ "vfat" ];

      # Include firmware needed for Surface hardware (keyboard, touch)
      includeDefaultModules = true;

      luks.devices."pool" = {
        device = "/dev/disk/by-uuid/3c75c6db-4d7c-4570-81f1-02d168781aac";
        preLVM = true;
        allowDiscards = true;

        # FALLBACK: USB keyfile on Ventoy VTOYEFI partition (UUID: 223C-F3F8)
        # Boot flow:
        #   1. Wait up to 5 seconds for USB keyfile
        #   2. If found, unlock automatically
        #   3. If not found, prompt for password
        keyFile = "/usb-key/.luks/surface.key";
        keyFileSize = 4096;
        keyFileTimeout = 5;
        fallbackToPassword = true;

        # Pre-open: mount USB to find keyfile
        preOpenCommands = ''
          echo "[USB-KEY] Searching for USB keyfile..."
          mkdir -p /usb-key

          # Wait for USB device to appear (max 5 seconds)
          attempts=0
          usb_found=0
          while [ $attempts -lt 5 ]; do
            if [ -b /dev/disk/by-uuid/223C-F3F8 ]; then
              echo "[USB-KEY] USB device found, mounting..."
              if mount -t vfat -o ro,iocharset=utf8 /dev/disk/by-uuid/223C-F3F8 /usb-key 2>&1; then
                if [ -f /usb-key/.luks/surface.key ]; then
                  echo "[USB-KEY] Keyfile found!"
                  usb_found=1
                  break
                else
                  echo "[USB-KEY] WARNING: USB mounted but keyfile not found at .luks/surface.key"
                  ls -la /usb-key/ 2>/dev/null || true
                  umount /usb-key 2>/dev/null || true
                fi
              else
                echo "[USB-KEY] Mount failed"
              fi
            fi
            attempts=$((attempts + 1))
            echo "[USB-KEY] Waiting for USB... ($attempts/5)"
            sleep 1
          done

          if [ $usb_found -eq 0 ]; then
            echo "[USB-KEY] No USB keyfile found, will prompt for password"
          fi
        '';

        # Post-open: cleanup USB mount
        postOpenCommands = ''
          umount /usb-key 2>/dev/null || true
        '';
      };
    };

    kernelModules = [ "kvm-intel" ];
    extraModulePackages = [ ];

    # NixOS-independent GRUB (won't touch Kubuntu's GRUB)
    loader = {
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot/efi";
      };
      grub = {
        enable = true;
        device = "nodev";  # EFI install, not MBR
        efiSupport = true;
        efiInstallAsRemovable = false;
        # Install to its own directory, don't overwrite Kubuntu
        extraInstallCommands = ''
          # Copy NixOS boot files to separate directory
          mkdir -p /boot/efi/EFI/nixos
        '';
      };
    };
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

  # Kubuntu root - read-only access to host OS
  fileSystems."/mnt/kubuntu" = {
    device = "/dev/disk/by-uuid/7e3626ac-ce13-4adc-84e2-1a843d7e2793";
    fsType = "ext4";
    options = [ "ro" "noatime" "nofail" ];
  };

  # 8GB swap file on pool
  swapDevices = [{
    device = "/mnt/shared/.swapfile";
    size = 8192;  # 8GB in MB
  }];

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE
  # ═══════════════════════════════════════════════════════════════════════════

  # Surface Pro 8 has Intel Tiger Lake
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware for WiFi, etc.
  hardware.enableRedistributableFirmware = true;

  # Power management - no CPU cap, full performance
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # Platform
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
