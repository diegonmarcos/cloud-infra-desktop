# Boot Configuration: initrd, LUKS unlock, kernel modules
# GENERATED FROM aa_bootloader/src/boot.json
# DO NOT EDIT BY HAND — re-generate via: aa_bootloader/build.sh deploy --target nixos
#
# IMPORTANT: NONE OF WHAT THIS MODULE SETS REBUILDS THE KERNEL.
# ─────────────────────────────────────────────────────────────
# `availableKernelModules`, `kernelModules`, `supportedFilesystems`,
# `luks.devices.*`, `kernelModules` (top-level) are all CONSUMERS of the
# kernel package — they tell the initrd which prebuilt .ko files to
# include / load, and they tell the running kernel which modules to load
# at boot. They DO NOT add new modules to the kernel source tree, do not
# change kernel CONFIG_*, do not modify any patch set.
#
# The kernel itself is selected in hardware_surface.nix
# (`hardware.microsoft-surface.kernelVersion = "stable"`). That's the only
# line in this flake that decides whether a kernel build runs. See that
# file's comment block for the cost rationale.
{ config, lib, pkgs, ... }:

let
  bootCfg = builtins.fromJSON (builtins.readFile ./boot.json);
  initrd = bootCfg.initrd;
  luks = initrd.luks;
in
{
  boot.initrd = {
    availableKernelModules = initrd.available_modules;
    kernelModules = initrd.early_modules;
    supportedFilesystems = initrd.supported_filesystems;
    includeDefaultModules = initrd.include_default_modules;

    luks.devices.${luks.device_name} = {
      device = "/dev/disk/by-uuid/${luks.device_uuid}";
      preLVM = luks.pre_lvm;
      allowDiscards = luks.allow_discards;

      keyFile = lib.mkIf (luks.keyfile.enabled or false)
        "/usb-key${luks.keyfile.path}";
      keyFileSize = lib.mkIf (luks.keyfile.enabled or false)
        luks.keyfile.size;
      fallbackToPassword = luks.fallback_password;

      # Mount Surface keyboard modules + try USB keyfile before prompting password
      preOpenCommands = lib.mkIf (luks.keyfile.enabled or false) ''
        echo "[SURFACE] Loading keyboard modules..."
        ${lib.concatMapStringsSep "\n" (mod: "modprobe ${mod} 2>/dev/null || true") luks.surface_keyboard_modules}
        sleep 2

        echo "[USB-KEY] Searching for USB keyfile..."
        mkdir -p /usb-key
        if [ -b /dev/disk/by-uuid/${luks.keyfile.usb_uuid} ]; then
          if mount -t vfat -o ro,iocharset=utf8 /dev/disk/by-uuid/${luks.keyfile.usb_uuid} /usb-key 2>&1; then
            if [ -f /usb-key${luks.keyfile.path} ]; then
              echo "[USB-KEY] Keyfile found!"
            else
              umount /usb-key 2>/dev/null || true
            fi
          fi
        fi
      '';

      postOpenCommands = lib.mkIf (luks.keyfile.enabled or false) ''
        umount /usb-key 2>/dev/null || true
      '';
    };
  };

  boot.kernelModules = bootCfg.boot_kernel_modules;
  boot.extraModulePackages = [];
}
