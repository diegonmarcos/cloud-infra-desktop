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
  # GIT — system-wide safe.directory for nixos-rebuild via sudo on user flakes
  # ═══════════════════════════════════════════════════════════════════════════
  # Without this, `sudo nixos-rebuild switch --flake /home/diego/git/...`
  # fails with "repository path is not owned by current user" because
  # nix's libgit2 honors git's CVE-2022-24765 ownership check. The build.sh
  # engine also injects GIT_CONFIG_* env vars as a runtime backstop.
  programs.git = {
    enable = true;
    config = {
      safe.directory = [ "*" ];
    };
  };

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
    ./configuration_system-protection-disk.nix
    ./configuration_system-protection-storage.nix
    ./configuration_system-protection-battery.nix
    ./configuration_power.nix
    ./configuration_pre-hibernate-warning.nix
    ./configuration_swapfile_resume_check.nix
    ./configuration_pool_witness.nix              # POST-2026-05-15: nonce-based detection of out-of-band pool mounts
    ./configuration_rescue_invalidate_hibernate.nix  # POST-2026-05-15: rewrite swap header on rescue boots so no stale resume
    ./configuration_kernel_preservation.nix       # POST-2026-05-15: mirror kernel+initrd nix-store closure to /boot so a pool wipe never destroys the prebuilt kernel
    ./configuration_activation_verify.nix         # POST-2026-05-16: loud post-activation invariant checks (users in shadow, swap not on btrfs, critical paths exist) so silent failures don't slip through
    ./configuration_tmp.nix
    ./configuration_packages.nix
    ./configuration_persistence.nix
    ./configuration_services.nix
    ./configuration_rescue.nix
    ./configuration_rescue_native-install.nix
    ./configuration_fallback.nix
    ./configuration_session_isolation.nix
    ./configuration_observability.nix
  ];
}
