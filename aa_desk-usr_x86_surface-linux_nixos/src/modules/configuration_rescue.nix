# Rescue mode boot specialisation — text-only recovery environment (CURRENT-GEN)
#
# This is the FAST-PATH rescue: same generation, same kernel, same initrd, same
# root identity, same custom modules — but with all DM/DE/desktop services
# force-disabled and root auto-logged in on tty1. Useful when a config-layer
# regression broke the desktop or an idle/lid/hibernate hook misfired.
#
# It does NOT protect against:
#   - kernel regressions (shared kernel)
#   - initrd / LUKS unlock breakage (shared key paths)
#   - root identity drift (shared user definition)
#   - nixpkgs upgrade regressions (shared flake input)
#
# For those scenarios, see configuration_rescue_native-install.nix
# (`rescue-native-install` specialisation — clean module set, no custom code,
# full dev environment) and the cross-distro tiers (Rescue-OS-Debian on p6,
# Kali on p7, Ventoy USB).
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # RESCUE MODE — current-gen (boot specialisation)
  # ═══════════════════════════════════════════════════════════════════════════
  # Appears in rEFInd as "NixOS - rescue-current-gen"
  # - No desktop (text mode only)
  # - Auto-login as root on TTY1
  # - WiFi available via nmtui/nmcli
  # - Recovery tools included

  specialisation.rescue-current-gen.configuration = {
    # Invalidate any pending hibernate image (safe swapfile-header rewrite,
    # gated on noresume) so the next default boot can't resume stale RAM
    # state on top of whatever this rescue session modified.
    # boot.json: swap_hibernate.hibernate_invalidation.trigger_specialisations
    imports = [ ./configuration_rescue_invalidate_hibernate.nix ];

    # boot.json: kernel.specialisations.rescue-current-gen.swap_disabled.
    # No disk swap in rescue — the swapfile stays untouched except for the
    # explicit invalidation above. (zram swap is unaffected.)
    swapDevices = lib.mkForce [ ];

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
      ║              NIXOS RESCUE — current-gen                           ║
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

    # CRITICAL: Do NOT resume from hibernation in rescue mode!
    # Remove resume= and resume_offset= and add noresume so we get a fresh
    # boot. This allows escaping hibernate loops and fixing broken configs.
    # `noresume` is also the ConditionKernelCommandLine gate that allows
    # rescue-invalidate-hibernate.service to act (defense-in-depth: the
    # invalidator can never fire on a resume-capable boot).
    boot.kernelParams = lib.mkForce [ "noresume" "mem_sleep_default=deep" "psi=1" "loglevel=4" "audit=1" ];
    boot.resumeDevice = lib.mkForce "";
  };
}
