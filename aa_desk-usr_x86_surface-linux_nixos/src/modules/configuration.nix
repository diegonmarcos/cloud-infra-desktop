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
    # ─── POST-2026-05-16 SIMPLIFICATION, PARTIALLY REVERTED 2026-06-12 ────
    # The hibernate-safety modules were stripped 2026-05-16 per user request
    # ("use the native hibernation module from the OS"). But the stripped
    # config was never deployed: the machine kept running the 2026-05-16
    # generation, whose rescue-invalidate-hibernate unit dd-zeroed the ext4
    # superblock of p5 (it targeted the resume PARTITION instead of the
    # swapfile) — which silently removed all hibernate-capable swap. On
    # 2026-06-12 the battery hit critical, every hibernate call failed with
    # "Not enough suitable swap space", and the machine drained dead.
    # Post-incident decision ("make it well done"): the WRITE-SAFETY gates
    # come back; only the UX/consistency extras stay out.
    #
    # IN (hibernate write-safety):
    #   - configuration_swapfile_resume_check.nix — triple-agreement gate
    #     (cmdline == /sys == actual swapfile extent) + resume-device-is-
    #     backing-device assertion + late-device /sys/power/resume
    #     registration. Masks hibernate on ANY drift so the image can never
    #     be written to / read from an unexpected location (2026-05-15 class).
    #   - configuration_rescue_invalidate_hibernate.nix — REWRITTEN: safe
    #     swapfile-header rewrite (never touches the partition), gated on
    #     ConditionKernelCommandLine=noresume, imported ONLY by the rescue
    #     specialisations (configuration_rescue*.nix), not here.
    #
    # IN again (2026-06-13, owner requirement — no immediate hibernation):
    #   - configuration_pre-hibernate-warning.nix — universal ExecStartPre on
    #     systemd-hibernate.service: EVERY hibernation path (watchdog, UPower,
    #     idle, manual) is delayed 30s and announced on desktop (notify-send)
    #     AND terminal (wall, with the inline cancel command) before it runs.
    #     Also still carries the invariant preflight gate.
    #
    # OUT (left as dead code in tree):
    #   - configuration_pool_witness.nix            (out-of-band mount detector)
    ./configuration_swapfile_resume_check.nix
    ./configuration_pre-hibernate-warning.nix     # 2026-06-13: 30s cancellable warning gate on every hibernation path (desktop + terminal); knobs in cloud-data-power.json pre_hibernate_warning
    ./configuration_session-checkpoint.nix        # 2026-06-12: periodic read-only btrfs snapshot of @home-diego — a session file on disk AT ALL TIMES (complements the event-driven hibernate image); policy in cloud-data-session-checkpoint.json
    ./configuration_kernel_preservation.nix       # POST-2026-05-15: mirror kernel+initrd nix-store closure to /boot so a pool wipe never destroys the prebuilt kernel
    ./configuration_activation_verify.nix         # POST-2026-05-16: loud post-activation invariant checks (users in shadow, swap not on btrfs, critical paths exist) so silent failures don't slip through
    ./configuration_btrfs_subvols_autocreate.nix  # POST-2026-05-16: walk config.fileSystems for declared btrfs subvols, auto-create any missing on /mnt/btrfs-root (fixes @shared/journal-not-created → no persistent journal class of bug)
    ./configuration_p5_diagnostic.nix             # POST-2026-05-16: forensic instrumentation for repeating p5 corruption (boot/shutdown fsck check + superblock+groups-945-947 sha256 snapshots + iostat capture + dmesg trace). All output → /var/log/p5-diag/ and journalctl -t p5-diagnostic
    ./configuration_home_ownership_repair.nix     # POST-2026-05-16: defensive chown of fragile $HOME paths (.claude/.config/.local/.ssh) on every activation — fixes class-of-bug where install/chroot flows leak root-owned files into /home/$user that then break standalone home-manager apply
    ./configuration_tmp.nix
    ./configuration_packages.nix
    ./configuration_persistence.nix
    ./configuration_services.nix
    ./configuration_rescue.nix
    ./configuration_rescue_native-install.nix
    ./configuration_fresh_desktop.nix             # 2026-06-12: "NixOS - Fresh Desktop" rEFInd entry — full Plasma with noresume + safe hibernate-image invalidation; the boot-menu counterpart to Primary's auto-resume (boot.json kernel.specialisations.fresh-desktop)
    ./configuration_fallback.nix
    ./configuration_session_isolation.nix
    ./configuration_observability.nix
  ];
}
