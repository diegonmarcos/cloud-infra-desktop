# System packages, shells, flatpak
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # SYSTEM PACKAGES - MINIMAL
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ─── Waydroid launcher ─────────────────────────────────────────────────
    (writeShellScriptBin "waydroid-launch" ''
      # Start container if not running
      if ! systemctl is-active --quiet waydroid-container; then
        sudo systemctl start waydroid-container
        sleep 2
      fi
      # Start session if not running
      if ! waydroid status 2>/dev/null | grep -q "Session.*RUNNING"; then
        waydroid session start &
        sleep 3
      fi
      # Show UI
      waydroid show-full-ui
    '')

    # ─── Absolute Minimum CLI (system-level only) ───────────────────────────
    # vim, git, curl, wget, nodejs → managed by home-manager profiles
    fish  # Must be here for users.users.*.shell = pkgs.fish

    # ─── System tools (required for maintenance / boot) ─────────────────────
    btrfs-progs
    cryptsetup
    # aa_bootloader (../aa_bootloader/) is the SoT for boot; its build.sh
    # needs these tools at deploy time. Without them, the engine falls back
    # to scanning /nix/store, which is fragile.
    efibootmgr   # NVRAM management (apply.sh + install-refind.sh)
    grub2_efi    # grub-mkimage + modules dir for render-grub-binaries.sh

    # ─── Openbox session essentials (launched by SDDM, must be system-level) ─
    openbox obconf
    polybar nitrogen feh rofi dunst picom xterm

    # ─── Wayland kiosk ──────────────────────────────────────────────────────
    cage wlr-randr

    # ─── SDDM Astronaut Theme (Qt6) - custom glassmorphism ───────────────────
    sddm-astronaut-custom

    # ─── Virtual Keyboard (Surface Pro touchscreen) ───────────────────────────
    # Must be system-level: used at SDDM login screen (pre-user-session)
    # NOTE: maliit-keyboard REMOVED — causes trackpad click freeze on Plasma 6 Wayland
    #   see: https://github.com/maliit/keyboard/issues/210
    # maliit-keyboard
    # maliit-framework
    onboard              # Full-featured: arrows, Fn keys, mouse buttons, word prediction
    kdePackages.qtvirtualkeyboard  # Qt virtual keyboard for SDDM login screen

    # ─── Wallpapers ───────────────────────────────────────────────────────────
    kdePackages.plasma-workspace-wallpapers

    # ─── KDE system-level integrations ────────────────────────────────────────
    # kdeconnect needs system D-Bus + firewall rules via programs.kdeconnect
    kdePackages.kdeconnect-kde

    # All other KDE apps → managed by home-manager profile 7 (productivity)
    #                      and profile 8 (media-graphics)
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # SHELLS
  # ═══════════════════════════════════════════════════════════════════════════

  programs.fish.enable = true;
  programs.zsh.enable = true;
  programs.bash.completion.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # FLATPAK (For user apps)
  # ═══════════════════════════════════════════════════════════════════════════

  services.flatpak.enable = true;

  # Add Flathub remote on boot (only if not already configured)
  # Uses ConditionPathExists to skip entirely if flathub is already set up
  systemd.services.flatpak-add-flathub = {
    description = "Add Flathub remote to Flatpak";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nss-lookup.target" ];
    wants = [ "network-online.target" "nss-lookup.target" ];
    unitConfig = {
      # Skip if flathub remote already exists (persisted in /var/lib/flatpak)
      ConditionPathExists = "!/var/lib/flatpak/repo/flathub.trustedkeys.gpg";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Retry up to 3 times with 10s delay between attempts
      Restart = "on-failure";
      RestartSec = "10s";
      RestartMaxDelaySec = "30s";
      StartLimitIntervalSec = "120";
      StartLimitBurst = "3";
      ExecStart = pkgs.writeShellScript "flatpak-add-flathub" ''
        # Wait for DNS to be available
        for i in 1 2 3 4 5; do
          if ${pkgs.iputils}/bin/ping -c1 -W2 flathub.org >/dev/null 2>&1; then
            break
          fi
          echo "[FLATPAK] Waiting for network... (attempt $i/5)"
          sleep 2
        done

        echo "[FLATPAK] Adding Flathub remote..."
        if ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
          echo "[FLATPAK] SUCCESS: Flathub remote added"
        else
          echo "[FLATPAK] ERROR: Failed to add Flathub (exit $?)" >&2
          echo "[FLATPAK] HINT: Run manually: flatpak remote-add flathub https://flathub.org/repo/flathub.flatpakrepo" >&2
          exit 1
        fi
      '';
    };
  };
}
