# Persistence: machine-id, journald, tmpfiles, activation scripts, bluetooth/NM symlinks
{ config, pkgs, lib, ... }:

let
  # nixSpecs: shell body lives in ./nix-specs.sh, data-driven at runtime from
  # /etc/cloud-data/nix-specs.json (declared below) instead of the repo path
  # being Nix-interpolated straight into the activation script.
  nixSpecsScript = pkgs.writeShellApplication {
    name = "nix-specs";
    runtimeInputs = [ pkgs.jq pkgs.util-linux pkgs.coreutils ];
    text = builtins.readFile ./nix-specs.sh;
  };

  # networkmanager-persistent / bluetooth-persistent: the two ExecStart
  # bodies were near-identical hand-duplicated heredocs. Both are now this
  # ONE data-driven script (./shared-symlink.sh), selecting which entry to
  # apply at runtime by name from /etc/cloud-data/shared-symlinks.json.
  sharedSymlinkScript = pkgs.writeShellApplication {
    name = "shared-symlink";
    runtimeInputs = [ pkgs.jq pkgs.util-linux pkgs.coreutils ];
    text = builtins.readFile ./shared-symlink.sh;
  };
in

{
  # Runtime data for nixSpecs and shared-symlink (new cloud-data paths —
  # verified against the already-declared environment.etc."cloud-data/..."
  # set, no collisions).
  environment.etc."cloud-data/nix-specs.json".source = ./nix-specs.json;
  environment.etc."cloud-data/shared-symlinks.json".source = ./shared-symlinks.json;
  # ═══════════════════════════════════════════════════════════════════════════
  # MACHINE IDENTITY (Hardcoded - stable across reboots)
  # ═══════════════════════════════════════════════════════════════════════════

  # Fixed machine-id (generate once: cat /proc/sys/kernel/random/uuid | tr -d '-')
  environment.etc."machine-id".text = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4";

  # ═══════════════════════════════════════════════════════════════════════════
  # JOURNALD (Survive hard freezes)
  # ═══════════════════════════════════════════════════════════════════════════

  # Storage/sync/seal ONLY. Rate-limiting + MaxLevel* are owned by
  # cloud-data-disk-protection.json (journald_limits) via
  # configuration_system-protection-disk.nix — single source of truth. Do NOT
  # re-add RateLimit*/MaxLevel* here: hardcoding RateLimitBurst=0 (unlimited)
  # here is what let the 2026-07-08 ~87k-lines/min log storm run unbounded.
  services.journald.storage = "persistent";
  services.journald.extraConfig = ''
    SyncIntervalSec=1s
    Compress=yes
    MaxLevelConsole=info
    Seal=yes
    SplitMode=uid
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # TMPFILES RULES
  # ═══════════════════════════════════════════════════════════════════════════

  systemd.tmpfiles.rules = [
    # CRITICAL: Nix build directory on disk (not tmpfs)
    # Kernel builds need 5-10GB, tmpfs only has ~4GB → "No space left" errors
    "d /var/tmp/nix-build 1777 root root -"

    # Tools directories
    "d /mnt/shared/tools/base/bin 0755 diego users -"
    "d /mnt/shared/tools/dev/bin 0755 diego users -"
    "d /mnt/shared/tools/data/bin 0755 diego users -"
    "d /mnt/shared/tools/devops/bin 0755 diego users -"
    "d /mnt/shared/tools/scripts 0755 diego users -"

    # Configs directory
    "d /mnt/shared/configs 0755 diego users -"

    # Data directories
    "d /mnt/shared/data/cache/cargo 0755 diego users -"
    "d /mnt/shared/data/cache/npm 0755 diego users -"
    "d /mnt/shared/data/cache/pip 0755 diego users -"
    "d /mnt/shared/data/cache/go 0755 diego users -"
    "d /mnt/shared-lib/docker 0755 root root -"
    "d /mnt/shared/data/vm 0755 diego users -"
    "d /mnt/shared/data/fonts 0755 diego users -"
    "d /mnt/shared/data/themes 0755 diego users -"

    # Mount points
    "d /mnt/shared/mnt 0755 diego users -"

    # ─── USER HOME DIRECTORIES (Fix permission issues) ────────────────────────
    # CRITICAL: Ensure ~/.local structure exists with correct ownership
    # This fixes Issues #2, #5, #6, #7, #10, #12, #14, #15
    # These directories may have been created as root when subvolumes were made

    # Diego's home structure
    "d /home/diego/.local 0700 diego users -"
    "d /home/diego/.local/share 0700 diego users -"
    "d /home/diego/.local/share/Trash 0700 diego users -"
    "d /home/diego/.local/share/Trash/files 0700 diego users -"
    "d /home/diego/.local/share/Trash/info 0700 diego users -"
    "d /home/diego/.local/share/keyrings 0700 diego users -"
    "d /home/diego/.local/share/bluetooth 0700 diego users -"
    "d /home/diego/.local/state 0700 diego users -"
    "d /home/diego/.local/state/nix 0700 diego users -"
    "d /home/diego/.cache 0700 diego users -"
    "d /home/diego/.config 0700 diego users -"

    # Guest's home structure
    "d /home/guest/.local 0700 guest users -"
    "d /home/guest/.local/share 0700 guest users -"
    "d /home/guest/.local/share/Trash 0700 guest users -"
    "d /home/guest/.local/share/Trash/files 0700 guest users -"
    "d /home/guest/.local/share/Trash/info 0700 guest users -"
    "d /home/guest/.local/share/keyrings 0700 guest users -"
    "d /home/guest/.local/share/bluetooth 0700 guest users -"
    "d /home/guest/.local/state 0700 guest users -"
    "d /home/guest/.cache 0700 guest users -"
    "d /home/guest/.config 0700 guest users -"
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # ACTIVATION SCRIPTS
  # ═══════════════════════════════════════════════════════════════════════════

  # NOTE: GRUB activation script (was: system.activationScripts.updateGrub)
  # removed in cleanup-after-rEFInd-yield. Bootloader is now owned by
  # aa_bootloader/; run `aa_bootloader/build.sh deploy` after any change.

  # FIX Issue #17: Create /bin/bash for script compatibility
  # NixOS doesn't have /bin/bash by default, but 99% of scripts expect it
  system.activationScripts.binBash = ''
    echo "[BASH] Creating /bin/bash symlink..."
    if mkdir -p /bin 2>/dev/null; then
      if ln -sf ${pkgs.bash}/bin/bash /bin/bash 2>/dev/null; then
        echo "[BASH] /bin/bash -> ${pkgs.bash}/bin/bash"
      else
        echo "[BASH] ERROR: Failed to create symlink" >&2
      fi
    else
      echo "[BASH] ERROR: Failed to create /bin directory" >&2
    fi
  '';

  # FIX Issue #4: Disable command-not-found (using flakes, no channels)
  programs.command-not-found.enable = false;

  # ═══════════════════════════════════════════════════════════════════════════
  # /nix/specs/ - SYSTEM SPECIFICATIONS & CONFIG
  # ═══════════════════════════════════════════════════════════════════════════
  # Creates /nix/specs/ with symlink to git repo containing:
  #   - flake.nix, configuration.nix, hardware-configuration.nix
  #   - USER-MANUAL.md (quick reference)
  #   - ARCHITECTURE.md (technical docs)
  #   - ISSUES-STATUS.md (known issues)
  #
  # Canonical source: /home/diego/git/unix/aa_nixos-surface_host/
  # Convenient access: /nix/specs/

  system.activationScripts.nixSpecs = "${nixSpecsScript}/bin/nix-specs";

  # ═══════════════════════════════════════════════════════════════════════════
  # BLUETOOTH PERSISTENCE (via @shared)
  # ═══════════════════════════════════════════════════════════════════════════
  # Bluetooth pairings stored in @shared for cross-OS sharing (NixOS + chainloaded OSes)
  # This is adapter-specific (hardware), not user-specific
  # Symlink WiFi connections -> /mnt/shared/NetworkManager at boot

  systemd.services.networkmanager-persistent = {
    description = "Symlink NetworkManager connections to @shared";
    wantedBy = [ "multi-user.target" ];
    before = [ "NetworkManager.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.util-linux pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${sharedSymlinkScript}/bin/shared-symlink networkmanager";
    };
  };

  # Symlink /var/lib/bluetooth -> /mnt/shared/bluetooth at boot

  systemd.services.bluetooth-persistent = {
    description = "Symlink Bluetooth pairings to @shared";
    wantedBy = [ "multi-user.target" ];
    before = [ "bluetooth.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.util-linux pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${sharedSymlinkScript}/bin/shared-symlink bluetooth";
    };
  };
}
