# GRUB Extra Entries - All OSes
# Imported by hardware-configuration.nix

''
# ═══════════════════════════════════════════════════════════════════════════
# KUBUNTU OS
# ═══════════════════════════════════════════════════════════════════════════

menuentry "Kubuntu OS" --class kubuntu --class gnu-linux --class gnu --class os {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07
  linux /vmlinuz-6.18.2-surface-1 root=UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793 ro quiet splash i915.enable_psr=0 i915.enable_dc=0
  initrd /initrd.img-6.18.2-surface-1
}

submenu "Kubuntu Recovery Mode" --class kubuntu {
  menuentry "Kubuntu 6.18.2-surface-1" --class kubuntu {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07
    linux /vmlinuz-6.18.2-surface-1 root=UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793 ro recovery nomodeset dis_ucode_ldr
    initrd /initrd.img-6.18.2-surface-1
  }
  menuentry "Kubuntu 6.17.1-surface-2" --class kubuntu {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07
    linux /vmlinuz-6.17.1-surface-2 root=UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793 ro recovery nomodeset dis_ucode_ldr
    initrd /initrd.img-6.17.1-surface-2
  }
  menuentry "Kubuntu 6.8.0-90-generic" --class kubuntu {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07
    linux /vmlinuz-6.8.0-90-generic root=UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793 ro recovery nomodeset dis_ucode_ldr
    initrd /initrd.img-6.8.0-90-generic
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# ARCH OS
# ═══════════════════════════════════════════════════════════════════════════

menuentry "Arch OS" --class arch --class gnu-linux --class gnu --class os {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root 1648a2fb-f2ce-4da5-9966-645758a24929
  linux /boot/vmlinuz-linux-surface root=UUID=1648a2fb-f2ce-4da5-9966-645758a24929 rw
  initrd /boot/initramfs-linux-surface.img
}

submenu "Arch OS Recovery Mode" --class arch {
  menuentry "Arch (linux-surface fallback)" --class arch {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 1648a2fb-f2ce-4da5-9966-645758a24929
    linux /boot/vmlinuz-linux-surface root=UUID=1648a2fb-f2ce-4da5-9966-645758a24929 rw single
    initrd /boot/initramfs-linux-surface-fallback.img
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# KALI LINUX
# ═══════════════════════════════════════════════════════════════════════════

menuentry "Kali Linux" --class kali --class gnu-linux --class gnu --class os {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root 509491e4-d3a7-426d-9b78-4b024b24cc32
  linux /vmlinuz root=UUID=509491e4-d3a7-426d-9b78-4b024b24cc32 ro quiet splash
  initrd /initrd.img
}

submenu "Kali Linux Recovery Mode" --class kali {
  menuentry "Kali (single user)" --class kali {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 509491e4-d3a7-426d-9b78-4b024b24cc32
    linux /vmlinuz root=UUID=509491e4-d3a7-426d-9b78-4b024b24cc32 ro single
    initrd /initrd.img
  }
  menuentry "Kali (old kernel)" --class kali {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 509491e4-d3a7-426d-9b78-4b024b24cc32
    linux /vmlinuz.old root=UUID=509491e4-d3a7-426d-9b78-4b024b24cc32 ro quiet splash
    initrd /initrd.img.old
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# WINDOWS BOOT MANAGER
# ═══════════════════════════════════════════════════════════════════════════

menuentry "Windows Boot Manager" --class windows --class os {
  insmod part_gpt
  insmod fat
  search --no-floppy --fs-uuid --set=root 2CE0-6722
  chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}

# ═══════════════════════════════════════════════════════════════════════════
# USB BOOT OPTIONS
# ═══════════════════════════════════════════════════════════════════════════

menuentry "Boot from USB (UEFI)" --class usb --class os {
  insmod part_gpt
  insmod fat
  insmod chain
  search --no-floppy --set=root --file /EFI/BOOT/BOOTX64.EFI
  chainloader /EFI/BOOT/BOOTX64.EFI
}

menuentry "Boot from Ventoy USB" --class usb --class os {
  insmod part_gpt
  insmod fat
  insmod chain
  search --no-floppy --fs-uuid --set=root 223C-F3F8
  chainloader /EFI/BOOT/BOOTX64.EFI
}

menuentry "UEFI Firmware Settings" --class settings {
  fwsetup
}
''
