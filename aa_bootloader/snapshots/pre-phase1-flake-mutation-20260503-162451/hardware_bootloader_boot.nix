# Boot Configuration: LUKS, initrd, kernel modules
# Reads bootloader_boot.json - SOURCE OF TRUTH
{ config, lib, pkgs, ... }:

let
  # Load the boot configuration from JSON
  bootloaderConfig = builtins.fromJSON (builtins.readFile ./bootloader_boot.json);

in {
  # ═══════════════════════════════════════════════════════════════════════════
  # INITRD MODULES
  # ═══════════════════════════════════════════════════════════════════════════

  boot.initrd = {
    availableKernelModules = bootloaderConfig.initrd.available_kernel_modules;
    kernelModules = bootloaderConfig.initrd.kernel_modules;
    supportedFilesystems = bootloaderConfig.initrd.supported_filesystems;
    includeDefaultModules = bootloaderConfig.initrd.include_default_modules;

    # ═══════════════════════════════════════════════════════════════════════════
    # LUKS ENCRYPTION
    # ═══════════════════════════════════════════════════════════════════════════

    luks.devices.${bootloaderConfig.luks.device} = {
      device = "/dev/disk/by-uuid/${bootloaderConfig.luks.uuid}";
      preLVM = true;
      allowDiscards = true;

      # USB keyfile support
      keyFile = lib.mkIf (bootloaderConfig.luks.keyfile.enabled or false)
        "/usb-key${bootloaderConfig.luks.keyfile.path}";
      keyFileSize = lib.mkIf (bootloaderConfig.luks.keyfile.enabled or false)
        bootloaderConfig.luks.keyfile.size;
      fallbackToPassword = bootloaderConfig.luks.fallback_to_password;

      # Load Surface keyboard modules and mount USB for keyfile
      preOpenCommands = lib.mkIf (bootloaderConfig.luks.keyfile.enabled or false) ''
        echo "[SURFACE] Loading keyboard modules..."
        ${lib.concatMapStringsSep "\n" (mod: "modprobe ${mod} 2>/dev/null || true") bootloaderConfig.surface_pro_8.keyboard_modules}
        sleep 2

        echo "[USB-KEY] Searching for USB keyfile..."
        mkdir -p /usb-key
        if [ -b /dev/disk/by-uuid/${bootloaderConfig.luks.keyfile.usb_uuid} ]; then
          if mount -t vfat -o ro,iocharset=utf8 /dev/disk/by-uuid/${bootloaderConfig.luks.keyfile.usb_uuid} /usb-key 2>&1; then
            if [ -f /usb-key${bootloaderConfig.luks.keyfile.path} ]; then
              echo "[USB-KEY] Keyfile found!"
            else
              umount /usb-key 2>/dev/null || true
            fi
          fi
        fi
      '';

      # Unmount USB after LUKS unlock
      postOpenCommands = lib.mkIf (bootloaderConfig.luks.keyfile.enabled or false) ''
        umount /usb-key 2>/dev/null || true
      '';
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # KERNEL MODULES
  # ═══════════════════════════════════════════════════════════════════════════
  # NOTE: boot.kernelParams for hibernation (resume=, resume_offset=) are in
  # hardware_filesystems.nix since they're tied to the swapfile location.

  boot.kernelModules = bootloaderConfig.boot.kernel_modules;
  boot.extraModulePackages = [];
}
