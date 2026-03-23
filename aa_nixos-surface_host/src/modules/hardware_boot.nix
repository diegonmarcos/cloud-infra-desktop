# Boot: GRUB, EFI, LUKS, initrd modules, USB keyfile
{ config, lib, pkgs, ... }:

{
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
        # NOTE: intel_ish* removed - Surface Pro 8 uses SAM, not Intel ISH
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

          # Wait for USB device to appear (max 1 second)
          attempts=0
          usb_found=0
          while [ $attempts -lt 1 ]; do
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
  };
}
