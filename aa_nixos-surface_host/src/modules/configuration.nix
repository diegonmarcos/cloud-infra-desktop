# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║              NIXOS SURFACE PRO 8 - MINIMAL + USER AGNOSTIC                ║
# ║                                                                           ║
# ║   Extremely minimal: tmpfs root, SDDM + desktop sessions only            ║
# ║   User agnostic: NO /persist, fully detachable @home-* subvolumes        ║
# ║   All tools via shared profiles in @shared/profiles/                     ║
# ║   Sessions: KDE Plasma, GNOME, Openbox, Waydroid, Kiosk                  ║
# ║                                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ═══════════════════════════════════════════════════════════════════════════
# NO IMPERMANENCE MODULE
# ═══════════════════════════════════════════════════════════════════════════
#
# This system is USER AGNOSTIC with FULLY DETACHABLE homes:
#
#   - /home/diego and /home/guest are dedicated btrfs subvolumes
#   - They persist everything automatically (no bind mounts needed)
#   - SSH host keys regenerate on boot (ephemeral, accept warnings)
#   - machine-id is hardcoded (stable across reboots)
#   - WiFi passwords stored in user's keyring (~/.local/share/keyrings/)
#   - Bluetooth pairings stored in @shared/bluetooth (cross-OS)
#   - System logs go to persistent journal on @shared
#
# Benefits:
#   - True tmpfs root — nothing to manage, nothing to leak
#   - Home is fully portable — just mount the subvolume anywhere
#   - Multiple users work independently with their own subvolumes
#   - Guest user works out of the box with ephemeral sessions

{ config, pkgs, lib, plasma-manager, ... }:

{
  system.stateVersion = "24.11";
  nixpkgs.config.allowUnfree = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # FIRMWARE (Intel IPU6 camera, WiFi, Bluetooth, etc.)
  # ═══════════════════════════════════════════════════════════════════════════
  hardware.firmware = with pkgs; [ linux-firmware ];
  hardware.enableAllFirmware = true;

  imports = [
    ./configuration_nix.nix
    ./configuration_locale.nix
    ./configuration_network.nix
    ./configuration_security.nix
    ./configuration_display.nix
    ./configuration_audio.nix
    ./docker-daemon.nix
    ./configuration_containers.nix
    ./configuration_system-protection.nix
    ./configuration_system-protection-storage.nix
    ./configuration_packages.nix
    ./configuration_persistence.nix
    ./configuration_services.nix
    ./configuration_rescue.nix
    ./configuration_fallback.nix
    ./configuration_session_isolation.nix
  ];
}
