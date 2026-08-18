# Hardware orchestrator — imports all hardware submodules
#
# NOTE: This flake has NO bootloader configuration. The bootloader (GRUB,
# /boot/grub/grub.cfg, grubx64.efi, NVRAM, /boot/kernels/ placement) is
# managed entirely by aa_bootloader at /home/diego/git/cloud-unix/aa_bootloader.
# Run `aa_bootloader/build.sh deploy --target grub` after any nixos-rebuild.
#
# What stays here (OS-level boot prep, not bootloader):
#   - hardware_bootloader_boot.nix   initrd content + LUKS unlock scripts
#   - swap_hibernate.nix              swapDevices, boot.resumeDevice, resume= cmdline
#   These configure the OS's initrd/swap, not the bootloader itself.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./hardware_surface.nix
    ./hardware_filesystems.nix
    ./hardware_filesystems_nosnap.nix  # regenerable caches on their own subvols → excluded from session-checkpoint snapshots (2026-08-11: deleting 9.1G freed 0 bytes because snapshots pinned it)
    # OS-internal initrd + swap (bootloader proper is in aa_bootloader/)
    # GENERATED FROM aa_bootloader/dist/adapters/nixos/ — do not edit
    ./hardware_bootloader_boot.nix  # LUKS + initrd + kernel modules
    ./swap_hibernate.nix            # swapDevices + boot.resumeDevice + resume= kernelParams
    ./nixos_yield.nix               # NixOS yields bootloader → aa_bootloader owns it
  ];
}
