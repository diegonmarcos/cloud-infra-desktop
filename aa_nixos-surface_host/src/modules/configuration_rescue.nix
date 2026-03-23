# Rescue mode boot specialisation — text-only recovery environment
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # RESCUE MODE (Boot specialisation)
  # ═══════════════════════════════════════════════════════════════════════════
  # Appears in GRUB as "NixOS - Rescue"
  # - No desktop (text mode only)
  # - Auto-login as root on TTY1
  # - WiFi available via nmtui/nmcli
  # - Recovery tools included

  specialisation.rescue.configuration = {
    # Disable ALL graphical services
    services.displayManager.sddm.enable = lib.mkForce false;
    services.xserver.enable = lib.mkForce false;
    services.desktopManager.plasma6.enable = lib.mkForce false;
    services.xserver.desktopManager.gnome.enable = lib.mkForce false;

    # Force multi-user.target (text mode) instead of graphical.target
    # Mask display-manager so nothing pulls in graphical.target
    systemd.services.display-manager.enable = lib.mkForce false;
    systemd.services.display-manager.wantedBy = lib.mkForce [];

    # Auto-login root on TTY1
    services.getty.autologinUser = lib.mkForce "root";

    # Keep NetworkManager for WiFi (nmtui works in terminal)
    networking.networkmanager.enable = lib.mkForce true;

    # Rescue tools
    environment.systemPackages = with pkgs; [
      # Network (nmtui for WiFi)
      networkmanager  # Provides nmtui, nmcli
      iw
      wirelesstools
      wpa_supplicant
      inetutils       # ping, hostname, etc.
      curl
      wget

      # Filesystem
      btrfs-progs
      e2fsprogs
      dosfstools
      ntfs3g
      cryptsetup
      gptfdisk
      parted

      # Development (for Claude Code)
      nodejs          # npm, npx
      git

      # Recovery
      testdisk
      ddrescue
      rsync

      # Editors
      vim
      nano

      # System
      htop
      lsof
      strace
      pciutils
      usbutils
      smartmontools
      file
      tree

      # Nix tools
      nix-tree
      nix-diff
    ];

    # Show rescue banner on login
    environment.etc."motd".text = ''

      ╔═══════════════════════════════════════════════════════════════════╗
      ║                    NIXOS RESCUE MODE                              ║
      ╠═══════════════════════════════════════════════════════════════════╣
      ║                                                                   ║
      ║  WiFi:     nmtui  or  nmcli device wifi connect SSID password PW  ║
      ║  Claude:   bash ~/user/claude.sh  (after WiFi connected)          ║
      ║                                                                   ║
      ║  Rebuild:  nixos-rebuild switch --flake /nix/specs#surface        ║
      ║  Rollback: nixos-rebuild switch --rollback                        ║
      ║  Disks:    lsblk, btrfs fi show, cryptsetup status pool           ║
      ║                                                                   ║
      ║  Config:   /nix/specs/  or  vim /nix/specs/configuration.nix      ║
      ║  Logs:     journalctl -xb                                         ║
      ║  Exit:     reboot                                                 ║
      ║                                                                   ║
      ╚═══════════════════════════════════════════════════════════════════╝

    '';

    # Minimal boot (faster)
    boot.plymouth.enable = lib.mkForce false;
  };
}
