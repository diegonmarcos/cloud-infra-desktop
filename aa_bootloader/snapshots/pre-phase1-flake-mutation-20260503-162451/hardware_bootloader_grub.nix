# GRUB Bootloader Configuration
# Reads bootloader_grub.json - SOURCE OF TRUTH
{ config, lib, pkgs, ... }:

let
  # Load the GRUB configuration from JSON
  bootloaderConfig = builtins.fromJSON (builtins.readFile ./bootloader_grub.json);

  # Helper to generate Linux menu entry
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

  # Helper to generate chainloader entry
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

  # Generate Arch entries
  archEntries = lib.optionalString (bootloaderConfig.entries.arch.enabled or false) ''
    # ═══════════════════════════════════════════════════════════════════════════
    # ARCH OS
    # ═══════════════════════════════════════════════════════════════════════════

    ${mkLinuxEntry {
      label = bootloaderConfig.entries.arch.label;
      root_uuid = bootloaderConfig.entries.arch.root_uuid;
      kernel = bootloaderConfig.entries.arch.kernel;
      initrd = bootloaderConfig.entries.arch.initrd;
      options = bootloaderConfig.entries.arch.options;
      class = "arch";
    }}

    ${lib.optionalString (bootloaderConfig.entries.arch.recovery.enabled or false) ''
    submenu "${bootloaderConfig.entries.arch.label} Recovery Mode" --class arch {
      menuentry "Arch (linux-surface fallback)" --class arch {
        insmod part_gpt
        insmod ext2
        search --no-floppy --fs-uuid --set=root ${bootloaderConfig.entries.arch.root_uuid}
        linux ${bootloaderConfig.entries.arch.recovery.kernel} root=UUID=${bootloaderConfig.entries.arch.root_uuid} ${bootloaderConfig.entries.arch.recovery.options}
        initrd ${bootloaderConfig.entries.arch.recovery.initrd}
      }
    }
    ''}
  '';

  # Generate Kali entries
  kaliEntries = lib.optionalString (bootloaderConfig.entries.kali.enabled or false) ''
    # ═══════════════════════════════════════════════════════════════════════════
    # KALI LINUX
    # ═══════════════════════════════════════════════════════════════════════════

    ${mkLinuxEntry {
      label = bootloaderConfig.entries.kali.label;
      root_uuid = bootloaderConfig.entries.kali.root_uuid;
      kernel = bootloaderConfig.entries.kali.kernel;
      initrd = bootloaderConfig.entries.kali.initrd;
      options = bootloaderConfig.entries.kali.options;
      class = "kali";
    }}

    ${lib.optionalString (bootloaderConfig.entries.kali.recovery.enabled or false) ''
    submenu "${bootloaderConfig.entries.kali.label} Recovery Mode" --class kali {
      ${lib.concatMapStringsSep "\n" (mode: ''
      menuentry "${mode.label}" --class kali {
        insmod part_gpt
        insmod ext2
        search --no-floppy --fs-uuid --set=root ${bootloaderConfig.entries.kali.root_uuid}
        linux ${mode.kernel or bootloaderConfig.entries.kali.kernel} root=UUID=${bootloaderConfig.entries.kali.root_uuid} ${mode.options}
        initrd ${mode.initrd or bootloaderConfig.entries.kali.initrd}
      }
      '') bootloaderConfig.entries.kali.recovery.modes}
    }
    ''}
  '';

  # Generate Windows entry
  windowsEntries = lib.optionalString (bootloaderConfig.entries.windows.enabled or false) ''
    # ═══════════════════════════════════════════════════════════════════════════
    # WINDOWS BOOT MANAGER
    # ═══════════════════════════════════════════════════════════════════════════

    ${mkChainloaderEntry {
      label = bootloaderConfig.entries.windows.label;
      efi_uuid = bootloaderConfig.entries.windows.efi_uuid;
      efi_path = bootloaderConfig.entries.windows.efi_path;
      class = "windows";
    }}
  '';

  # Generate USB entries
  usbEntries = lib.optionalString (bootloaderConfig.entries.usb.enabled or false) ''
    # ═══════════════════════════════════════════════════════════════════════════
    # USB BOOT OPTIONS
    # ═══════════════════════════════════════════════════════════════════════════

    ${lib.concatMapStringsSep "\n" (entry:
      mkChainloaderEntry {
        label = entry.label;
        efi_uuid = entry.efi_uuid or null;
        search_file = entry.search_file or null;
        efi_path = entry.efi_path;
        class = "usb";
      }
    ) bootloaderConfig.entries.usb.entries}
  '';

  # Generate firmware entry
  firmwareEntries = lib.optionalString (bootloaderConfig.entries.firmware.enabled or false) ''
    menuentry "${bootloaderConfig.entries.firmware.label}" --class settings {
      fwsetup
    }
  '';

  # All extra entries combined
  allExtraEntries = ''
    ${archEntries}
    ${kaliEntries}
    ${windowsEntries}
    ${usbEntries}
    ${firmwareEntries}
  '';

in {
  # ═══════════════════════════════════════════════════════════════════════════
  # GRUB BOOTLOADER CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = bootloaderConfig.efi.install_as_removable;

    # Timeout and appearance
    default = bootloaderConfig.grub.default;
    timeout = bootloaderConfig.grub.timeout;
    gfxmodeEfi = bootloaderConfig.grub.gfxmode;
    gfxmodeBios = bootloaderConfig.grub.gfxmode;

    # LUKS support modules
    enableCryptodisk = true;

    # Multi-OS boot entries
    extraEntries = allExtraEntries;

    # Ensure EFI directory exists
    extraInstallCommands = ''
      ${pkgs.coreutils}/bin/mkdir -p ${bootloaderConfig.efi.sys_mount_point}/EFI/nixos
    '';
  };

  # EFI configuration
  boot.loader.efi = {
    canTouchEfiVariables = bootloaderConfig.efi.can_touch_variables;
    efiSysMountPoint = bootloaderConfig.efi.sys_mount_point;
  };
}
