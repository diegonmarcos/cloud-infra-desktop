# Hardware configuration for Surface Pro 8
# NixOS with Full Impermanence - tmpfs root

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # LINUX-SURFACE KERNEL
  # ═══════════════════════════════════════════════════════════════════════════
  # CRITICAL: Surface Pro 8 Type Cover keyboard requires linux-surface kernel
  # The mainline kernel lacks surface_aggregator_hub module needed for SAM

  hardware.microsoft-surface = {
    # Use stable linux-surface kernel (latest patched release)
    # Options: "stable" (latest) or "longterm" (LTS, default)
    kernelVersion = "stable";
  };

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
        # VFAT for USB keyfile - module names use hyphen (nls_iso8859-1.ko)
        "vfat" "fat" "nls_cp437" "nls_iso8859-1" "nls_utf8"
      ];
      # CRITICAL: Force-load these modules BEFORE LUKS prompt
      # ORDER MATTERS - dependencies must load first!
      kernelModules = [
        "dm-snapshot"

        # 1. FAT/VFAT for USB keyfile
        "vfat" "fat" "nls_cp437" "nls_iso8859-1" "nls_utf8"

        # 2. BUS & POWER SUBSYSTEMS (MUST LOAD FIRST!)
        "intel_lpss"              # Low Power Subsystem - SAM depends on this
        "intel_lpss_pci"
        "8250_dw"                 # UART for Surface Embedded Controller
        "pinctrl_tigerlake"       # GPIO controller for Tiger Lake
        "xhci_pci"                # USB controller (for keyfile fallback)

        # 3. SURFACE AGGREGATOR (The "Hub" - depends on LPSS)
        "surface_aggregator"
        "surface_aggregator_registry"
        "surface_aggregator_hub"

        # 4. SURFACE HID (Keyboard/Touchpad - depends on SAM)
        "surface_hid_core"
        "surface_hid"

        # 5. TOUCH/INPUT (Fallback)
        "hid_multitouch"
        "hid_generic"
        "i2c_hid"
        "i2c_hid_acpi"
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
        # keyFileTimeout requires systemd initrd - handled in preOpenCommands instead
        fallbackToPassword = true;

        # Pre-open: mount USB to find keyfile
        preOpenCommands = ''
          # CRITICAL: Force-load Surface keyboard modules BEFORE USB check
          # Without this, USB keyfile unlocks too fast and keyboard never loads
          echo "[SURFACE] Loading keyboard modules..."
          modprobe surface_aggregator 2>/dev/null || true
          modprobe surface_aggregator_registry 2>/dev/null || true
          modprobe surface_aggregator_hub 2>/dev/null || true
          modprobe surface_hid_core 2>/dev/null || true
          modprobe surface_hid 2>/dev/null || true
          modprobe hid_multitouch 2>/dev/null || true
          sleep 2  # Give modules time to initialize
          echo "[SURFACE] Keyboard modules loaded"

          echo "[USB-KEY] Searching for USB keyfile..."
          mkdir -p /usb-key

          # Wait for USB device to appear (max 15 seconds - Surface USB init is slow)
          attempts=0
          usb_found=0
          while [ $attempts -lt 15 ]; do
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

        # Post-open: cleanup USB mount and ensure keyboard is loaded
        postOpenCommands = ''
          umount /usb-key 2>/dev/null || true

          # SECOND STAGE: Ensure Surface keyboard modules are loaded after LUKS
          # This is a safety net in case first-stage loading failed
          echo "[SURFACE] Second-stage keyboard module check..."
          modprobe surface_aggregator 2>/dev/null || true
          modprobe surface_aggregator_registry 2>/dev/null || true
          modprobe surface_aggregator_hub 2>/dev/null || true
          modprobe surface_hid_core 2>/dev/null || true
          modprobe surface_hid 2>/dev/null || true
          echo "[SURFACE] Keyboard modules verified"
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

  # /nix - persistent Nix store
  fileSystems."/nix" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@nixos/nix" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  # NO /persist - system is user-agnostic
  # All persistent state goes to @shared or @home-*

  # /home/diego - main user home (nofail: boot continues if missing)
  fileSystems."/home/diego" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@home-diego" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # /home/guest - guest user home (nofail: boot continues if missing)
  fileSystems."/home/guest" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@home-guest" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # /mnt/shared - common storage for both OSes (nofail: boot continues if missing)
  fileSystems."/mnt/shared" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@shared" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
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

  # Waydroid base image (shared between users) - nofail for boot resilience
  fileSystems."/var/lib/waydroid" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@shared/waydroid-base" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Waydroid per-user data - diego - nofail for boot resilience
  fileSystems."/home/diego/.local/share/waydroid" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@home-diego/waydroid" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Waydroid per-user data - guest - nofail for boot resilience
  fileSystems."/home/guest/.local/share/waydroid" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@home-guest/waydroid" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Kubuntu root - read-only access to host OS
  fileSystems."/mnt/kubuntu" = {
    device = "/dev/disk/by-uuid/7e3626ac-ce13-4adc-84e2-1a843d7e2793";
    fsType = "ext4";
    options = [ "ro" "noatime" "nofail" ];
  };

  # 8GB swap file on pool (already exists, don't specify size)
  swapDevices = [{
    device = "/mnt/shared/.swapfile";
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
