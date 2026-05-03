# GRUB Bootloader Configuration
# GENERATED FROM aa_bootloader/src/boot.json
# DO NOT EDIT BY HAND — re-generate via: aa_bootloader/build.sh deploy --target nixos
#
# Phase 1: NixOS still authors /boot/grub/grub.cfg. We feed multi-OS menu
# entries via boot.loader.grub.extraEntries. Phase 3 will set
# boot.loader.grub.enable = false and let aa_bootloader own grub.cfg directly.
{ config, lib, pkgs, ... }:

let
  bootCfg = builtins.fromJSON (builtins.readFile ./boot.json);
  grubCfg = bootCfg.grub;
  uefi = bootCfg.uefi;

  # ── Helpers (shape borrowed from prior hardware_bootloader_grub.nix) ──

  mkLinuxEntry = { label, root_uuid, kernel, initrd, options ? "rw", class ? "gnu-linux" }:
    ''
      menuentry "${label}" --class ${class} --class gnu-linux --class gnu --class os {
        insmod part_gpt
        insmod ext2
        search --no-floppy --fs-uuid --set=root ${root_uuid}
        linux ${kernel} root=UUID=${root_uuid} ${options}
        initrd ${initrd}
      }
    '';

  mkChainloaderEntry = { label, efi_uuid ? null, search_file ? null, efi_path, class ? "os" }:
    ''
      menuentry "${label}" --class ${class} --class os {
        insmod part_gpt
        insmod fat
        insmod chain
        ${if search_file != null then
          "search --no-floppy --set=root --file ${search_file}"
        else
          "search --no-floppy --fs-uuid --set=root ${efi_uuid}"}
        chainloader ${efi_path}
      }
    '';

  # ── Per-OS menu fragments ──

  archEntries = lib.optionalString (grubCfg.menu.arch.enabled or false) ''
    # ─── ARCH ───
    ${mkLinuxEntry {
      label = grubCfg.menu.arch.label;
      root_uuid = grubCfg.menu.arch.root_uuid;
      kernel = grubCfg.menu.arch.kernel;
      initrd = grubCfg.menu.arch.initrd;
      options = grubCfg.menu.arch.options;
      class = "arch";
    }}

    ${lib.optionalString (grubCfg.menu.arch.recovery.enabled or false) ''
    submenu "Arch OS Recovery Mode" --class arch {
      menuentry "${grubCfg.menu.arch.recovery.label}" --class arch {
        insmod part_gpt
        insmod ext2
        search --no-floppy --fs-uuid --set=root ${grubCfg.menu.arch.root_uuid}
        linux ${grubCfg.menu.arch.recovery.kernel} root=UUID=${grubCfg.menu.arch.root_uuid} ${grubCfg.menu.arch.recovery.options}
        initrd ${grubCfg.menu.arch.recovery.initrd}
      }
    }
    ''}
  '';

  kaliEntries = lib.optionalString (grubCfg.menu.kali.enabled or false) ''
    # ─── KALI ───
    ${mkLinuxEntry {
      label = grubCfg.menu.kali.label;
      root_uuid = grubCfg.menu.kali.root_uuid;
      kernel = grubCfg.menu.kali.kernel;
      initrd = grubCfg.menu.kali.initrd;
      options = grubCfg.menu.kali.options;
      class = "kali";
    }}

    ${lib.optionalString (grubCfg.menu.kali.recovery.enabled or false) ''
    submenu "Kali Linux Recovery Mode" --class kali {
      ${lib.concatMapStringsSep "\n" (mode: ''
      menuentry "${mode.label}" --class kali {
        insmod part_gpt
        insmod ext2
        search --no-floppy --fs-uuid --set=root ${grubCfg.menu.kali.root_uuid}
        linux ${mode.kernel or grubCfg.menu.kali.kernel} root=UUID=${grubCfg.menu.kali.root_uuid} ${mode.options}
        initrd ${mode.initrd or grubCfg.menu.kali.initrd}
      }
      '') grubCfg.menu.kali.recovery.modes}
    }
    ''}
  '';

  windowsEntries = lib.optionalString (grubCfg.menu.windows.enabled or false) ''
    # ─── WINDOWS ───
    ${mkChainloaderEntry {
      label = grubCfg.menu.windows.label;
      efi_uuid = grubCfg.menu.windows.efi_uuid;
      efi_path = grubCfg.menu.windows.efi_path;
      class = "windows";
    }}
  '';

  usbEntries = lib.optionalString (grubCfg.menu.usb.enabled or false) ''
    # ─── USB ───
    ${lib.concatMapStringsSep "\n" (entry:
      mkChainloaderEntry {
        label = entry.label;
        efi_uuid = entry.efi_uuid or null;
        search_file = entry.search_file or null;
        efi_path = entry.efi_path;
        class = "usb";
      }
    ) grubCfg.menu.usb.entries}
  '';

  firmwareEntries = lib.optionalString (grubCfg.menu.firmware.enabled or false) ''
    menuentry "${grubCfg.menu.firmware.label}" --class settings {
      fwsetup
    }
  '';

  allExtraEntries = ''
    ${archEntries}
    ${kaliEntries}
    ${windowsEntries}
    ${usbEntries}
    ${firmwareEntries}
  '';

in {
  boot.loader.grub = {
    enable = true;
    device = grubCfg.install.device;
    efiSupport = true;
    efiInstallAsRemovable = grubCfg.install.efi_install_as_removable;
    enableCryptodisk = grubCfg.install.enable_cryptodisk;

    default = grubCfg.ui.default;
    timeout = grubCfg.ui.timeout;
    gfxmodeEfi = grubCfg.ui.gfxmode;
    gfxmodeBios = grubCfg.ui.gfxmode;

    configurationLimit = grubCfg.install.configuration_limit;

    extraEntries = allExtraEntries;

    extraInstallCommands = ''
      ${pkgs.coreutils}/bin/mkdir -p ${uefi.esp.mount}/EFI/nixos
    '';
  };

  boot.loader.efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = uefi.esp.mount;
  };
}
