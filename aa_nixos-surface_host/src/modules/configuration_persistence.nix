# Persistence: machine-id, journald, tmpfiles, activation scripts, bluetooth/NM symlinks
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # MACHINE IDENTITY (Hardcoded - stable across reboots)
  # ═══════════════════════════════════════════════════════════════════════════

  # Fixed machine-id (generate once: cat /proc/sys/kernel/random/uuid | tr -d '-')
  environment.etc."machine-id".text = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4";

  # ═══════════════════════════════════════════════════════════════════════════
  # JOURNALD (Survive hard freezes)
  # ═══════════════════════════════════════════════════════════════════════════

  services.journald.storage = "persistent";
  services.journald.extraConfig = ''
    SyncIntervalSec=1s
    Compress=yes
    MaxLevelStore=debug
    MaxLevelSyslog=debug
    MaxLevelKMsg=debug
    MaxLevelConsole=info
    RateLimitIntervalSec=0
    RateLimitBurst=0
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
    "d /home/diego/.local/share/waydroid 0700 diego users -"
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
    "d /home/guest/.local/share/waydroid 0700 guest users -"
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
  # Canonical source: /mnt/shared-lib/home/diego/mnt_git/unix/a_nixos_host/
  # Convenient access: /nix/specs/

  system.activationScripts.nixSpecs = ''
    echo "[SPECS] Setting up /nix/specs/..."
    SPECS_SRC="/mnt/shared-lib/home/diego/mnt_git/unix/a_nixos_host"

    # Check if source exists
    if [ -d "$SPECS_SRC" ]; then
      # Remove existing symlink/directory
      if [ -L /nix/specs ]; then
        rm -f /nix/specs
        echo "[SPECS] Removed old symlink"
      elif [ -d /nix/specs ]; then
        rm -rf /nix/specs
        echo "[SPECS] Removed old directory"
      fi

      # Create symlink
      if ln -sf "$SPECS_SRC" /nix/specs; then
        echo "[SPECS] SUCCESS: /nix/specs -> $SPECS_SRC"

        # Verify symlink works
        if [ -f /nix/specs/flake.nix ]; then
          echo "[SPECS] Verified: flake.nix accessible"
        else
          echo "[SPECS] WARNING: Symlink created but flake.nix not found" >&2
        fi
      else
        echo "[SPECS] ERROR: Failed to create symlink (exit $?)" >&2
      fi
    else
      # Source not found - check if kubuntu is mounted
      echo "[SPECS] WARNING: Config source not found at $SPECS_SRC" >&2

      if ! mountpoint -q /mnt/shared-lib 2>/dev/null; then
        echo "[SPECS] HINT: /mnt/shared-lib is not mounted" >&2
      fi

      # Create fallback directory with README
      mkdir -p /nix/specs
      cat > /nix/specs/README.md << 'SPECEOF'
# NixOS Specs - FALLBACK MODE

Configuration source not found at expected location.

## Expected Location
/mnt/shared-lib/home/diego/mnt_git/unix/a_nixos_host/

## Troubleshooting

1. Check if Kubuntu partition is mounted:
   mountpoint /mnt/shared-lib

2. Mount it manually:
   sudo mount /mnt/shared-lib

3. Rebuild NixOS to refresh symlink:
   sudo nixos-rebuild switch --flake /mnt/shared-lib/home/diego/mnt_git/unix/a_nixos_host#surface

## Alternative

The system is fully functional without /nix/specs.
Edit configuration directly at the source location.
SPECEOF
      echo "[SPECS] Created fallback README at /nix/specs/"
    fi
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # BLUETOOTH PERSISTENCE (via @shared)
  # ═══════════════════════════════════════════════════════════════════════════
  # Bluetooth pairings stored in @shared for cross-OS sharing (NixOS + Kubuntu)
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
      ExecStart = pkgs.writeShellScript "networkmanager-shared-symlink" ''
        echo "[NETWORKMANAGER] Setting up persistent WiFi storage..."

        # Check if @shared is mounted
        if ! mountpoint -q /mnt/shared 2>/dev/null; then
          echo "[NETWORKMANAGER] ERROR: /mnt/shared is not mounted" >&2
          exit 1
        fi

        # Create @shared NetworkManager directory if needed
        if mkdir -p /mnt/shared/NetworkManager/system-connections 2>/dev/null; then
          chmod 700 /mnt/shared/NetworkManager
          chmod 700 /mnt/shared/NetworkManager/system-connections
          echo "[NETWORKMANAGER] Created /mnt/shared/NetworkManager/system-connections"
        else
          echo "[NETWORKMANAGER] ERROR: Failed to create directory" >&2
          exit 1
        fi

        # Ensure /etc/NetworkManager exists
        mkdir -p /etc/NetworkManager

        # Remove any existing system-connections
        if [ -e /etc/NetworkManager/system-connections ]; then
          if rm -rf /etc/NetworkManager/system-connections 2>/dev/null; then
            echo "[NETWORKMANAGER] Removed existing system-connections"
          else
            echo "[NETWORKMANAGER] WARNING: Could not remove system-connections" >&2
          fi
        fi

        # Create symlink
        if ln -sf /mnt/shared/NetworkManager/system-connections /etc/NetworkManager/system-connections; then
          echo "[NETWORKMANAGER] SUCCESS: system-connections -> /mnt/shared/NetworkManager/system-connections"
        else
          echo "[NETWORKMANAGER] ERROR: Failed to create symlink" >&2
          exit 1
        fi
      '';
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
      ExecStart = pkgs.writeShellScript "bluetooth-shared-symlink" ''
        echo "[BLUETOOTH] Setting up persistent bluetooth storage..."

        # Check if @shared is mounted
        if ! mountpoint -q /mnt/shared 2>/dev/null; then
          echo "[BLUETOOTH] ERROR: /mnt/shared is not mounted" >&2
          exit 1
        fi

        # Create @shared bluetooth directory if needed
        if mkdir -p /mnt/shared/bluetooth 2>/dev/null; then
          chmod 700 /mnt/shared/bluetooth
          echo "[BLUETOOTH] Created /mnt/shared/bluetooth"
        else
          echo "[BLUETOOTH] ERROR: Failed to create /mnt/shared/bluetooth" >&2
          exit 1
        fi

        # Remove any existing /var/lib/bluetooth
        if [ -e /var/lib/bluetooth ]; then
          if rm -rf /var/lib/bluetooth 2>/dev/null; then
            echo "[BLUETOOTH] Removed existing /var/lib/bluetooth"
          else
            echo "[BLUETOOTH] WARNING: Could not remove /var/lib/bluetooth" >&2
          fi
        fi

        # Create symlink
        if ln -sf /mnt/shared/bluetooth /var/lib/bluetooth; then
          echo "[BLUETOOTH] SUCCESS: /var/lib/bluetooth -> /mnt/shared/bluetooth"
        else
          echo "[BLUETOOTH] ERROR: Failed to create symlink" >&2
          exit 1
        fi
      '';
    };
  };
}
