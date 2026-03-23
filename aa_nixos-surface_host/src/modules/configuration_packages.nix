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

    # ─── Absolute Minimum CLI ───────────────────────────────────────────────
    vim
    fish

    # ─── Bootstrap Tools (CRITICAL - for building user space) ───────────────
    firefox      # Web browser (authenticate, download, research)
    brave        # Privacy-focused browser
    git          # Version control (clone repos, manage dotfiles)
    wget         # Download tool
    curl         # Alternative download tool
    nodejs       # Includes npm, npx (for Claude Code and JS development)

    # ─── Productivity ─────────────────────────────────────────────────────────
    libreoffice  # Office suite
    obsidian     # Note-taking

    # ─── System tools (required for maintenance) ────────────────────────────
    pciutils
    usbutils
    btrfs-progs
    cryptsetup

    # ─── Openbox session essentials ─────────────────────────────────────────
    openbox obconf
    polybar nitrogen feh rofi dunst picom xterm

    # ─── Wayland kiosk ──────────────────────────────────────────────────────
    cage wlr-randr

    # ─── GUI dialogs ────────────────────────────────────────────────────────
    zenity kdialog

    # ─── SDDM Astronaut Theme (Qt6) - custom glassmorphism ───────────────────
    sddm-astronaut-custom

    # ─── Virtual Keyboard (Surface Pro touchscreen) ───────────────────────────
    maliit-keyboard
    maliit-framework
    onboard              # Full-featured: arrows, Fn keys, mouse buttons, word prediction
    kdePackages.qtvirtualkeyboard  # Qt virtual keyboard for SDDM login screen

    # ─── Wallpapers ───────────────────────────────────────────────────────────
    kdePackages.plasma-workspace-wallpapers

    # ─── KDE Applications Suite ───────────────────────────────────────────────
    kdePackages.kdeconnect-kde   # Phone/tablet integration
    kdePackages.kate             # Advanced text editor
    kdePackages.kcalc            # Calculator
    kdePackages.ark              # Archive manager
    kdePackages.okular           # Document viewer (PDF, etc.)
    kdePackages.gwenview         # Image viewer
    kdePackages.spectacle        # Screenshot tool
    kdePackages.dolphin          # File manager (likely already via Plasma)
    kdePackages.konsole          # Terminal (likely already via Plasma)
    kdePackages.kcolorchooser    # Color picker
    kdePackages.kmousetool       # Accessibility - auto-click
    kdePackages.partitionmanager # Disk partition manager
    kdePackages.filelight        # Disk usage visualizer
    kdePackages.kcharselect      # Character selector
    kdePackages.ksystemlog       # System log viewer
    kdePackages.kfind            # File search
    kdePackages.krdc             # Remote desktop client
    kdePackages.krfb             # Remote desktop server (VNC)
    kdePackages.elisa            # Music player
    kdePackages.dragon           # Video player
    # kdePackages.kamoso         # Camera app - BROKEN in nixpkgs
    kdePackages.skanlite         # Scanner app
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
