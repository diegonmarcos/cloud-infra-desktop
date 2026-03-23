# Filesystem mounts: btrfs, tmpfs root, EFI, swap, waydroid, persistent journal
{ config, lib, pkgs, ... }:

{
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

  # Persistent journal - survives tmpfs root wipes (logs available across reboots)
  fileSystems."/var/log/journal" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvol=@shared/journal" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # BTRFS ROOT - Shows all subvolumes (@home-diego, @home-guest, @nixos, @shared)
  fileSystems."/mnt/btrfs-root" = {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [ "subvolid=5" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10s" ];
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
}
