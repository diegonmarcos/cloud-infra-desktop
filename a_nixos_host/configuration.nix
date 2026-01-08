# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║              NIXOS SURFACE PRO 8 - MINIMAL + USER AGNOSTIC                ║
# ║                                                                           ║
# ║   Extremely minimal: tmpfs root, SDDM + desktop sessions only            ║
# ║   User agnostic: NO /persist, fully detachable @home-* subvolumes        ║
# ║   All tools via shared profiles in @shared/profiles/                     ║
# ║   Sessions: KDE Plasma, GNOME, Openbox, Waydroid, Kiosk                  ║
# ║                                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:

{
  system.stateVersion = "24.11";
  nixpkgs.config.allowUnfree = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # FIRMWARE (Intel IPU6 camera, WiFi, Bluetooth, etc.)
  # ═══════════════════════════════════════════════════════════════════════════
  hardware.firmware = with pkgs; [ linux-firmware ];
  hardware.enableAllFirmware = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════
  # NOTE: linux-surface kernel is cached LOCALLY in @nixos/nix after first build.
  # Kubuntu mounts @nixos/nix as /nix when building, so kernel is never rebuilt.
  # See architecture.md for ONE STORE design.
  # ═══════════════════════════════════════════════════════════════════════════
  nix.settings = {
    max-jobs = 4;
    substituters = [ "https://cache.nixos.org" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
  };

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
  #   - System logs go to tmpfs (or journal to @shared if needed)
  #
  # Benefits:
  #   - Plug @home-diego into ANY NixOS and it just works
  #   - No /persist subvolume needed
  #   - True separation between OS and user data
  #
  # ═══════════════════════════════════════════════════════════════════════════

  # ═══════════════════════════════════════════════════════════════════════════
  # MACHINE IDENTITY (Hardcoded - stable across reboots)
  # ═══════════════════════════════════════════════════════════════════════════

  # Fixed machine-id (generate once: cat /proc/sys/kernel/random/uuid | tr -d '-')
  environment.etc."machine-id".text = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4";

  # ═══════════════════════════════════════════════════════════════════════════
  # NETWORKING
  # ═══════════════════════════════════════════════════════════════════════════

  networking = {
    hostName = "surface-nixos";
    networkmanager.enable = lib.mkDefault true;  # ISO disables this
    firewall = {
      enable = lib.mkDefault true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # WIFI & BLUETOOTH PERSISTENCE
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # WiFi: Passwords stored in user's keyring (GNOME Keyring / KWallet)
  #       - Keyring is in ~/.local/share/keyrings/ (portable with home)
  #       - When user logs in, their saved WiFi networks auto-connect
  #       - Each user has their own WiFi passwords (per-user, portable)
  #
  # Bluetooth: Pairings stored in @shared/bluetooth (cross-OS)
  #       - Hardware/adapter-specific, not user-specific
  #       - Symlinked from /var/lib/bluetooth at boot
  #       - Shared between NixOS and Kubuntu
  #

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # KDE Connect - phone/tablet integration
  programs.kdeconnect.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # TIMEZONE AND LOCALE
  # ═══════════════════════════════════════════════════════════════════════════

  time.timeZone = "Europe/Madrid";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ALL = "en_US.UTF-8";
    LANG = "en_US.UTF-8";
  };
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "es_ES.UTF-8/UTF-8" ];

  # Console (TTY) keyboard layout - Spanish
  console.keyMap = "es";

  # ═══════════════════════════════════════════════════════════════════════════
  # USER ACCOUNTS (Fixed UIDs for cross-OS compatibility)
  # ═══════════════════════════════════════════════════════════════════════════

  users.mutableUsers = false;  # Users defined only in config, not /etc/passwd

  users.users.diego = {
    isNormalUser = true;
    description = "Diego";
    uid = 1000;
    group = "users";
    # Password: 1234567890 (hashedPassword ensures it works every boot, not just first)
    hashedPassword = "$6$0lk5nosoLlNAcDTp$or4FVVs/Lq1gFMYgjuw6FUdh6dKNE8e/vBClzgik290mxMCzctvN43odeGq7D.qpuJCyyDxJJAsSQNSsB3Vst0";
    extraGroups = [
      "wheel" "networkmanager" "video" "audio"
      "docker" "podman" "kvm" "libvirtd"
    ];
    shell = pkgs.fish;
    # Home is a dedicated btrfs subvolume - fully persistent
    home = "/home/diego";
  };

  users.users.guest = {
    isNormalUser = true;
    description = "Guest User";
    uid = 1001;
    group = "users";
    # Password: 1234567890 (same as diego for convenience)
    hashedPassword = "$6$0lk5nosoLlNAcDTp$or4FVVs/Lq1gFMYgjuw6FUdh6dKNE8e/vBClzgik290mxMCzctvN43odeGq7D.qpuJCyyDxJJAsSQNSsB3Vst0";
    extraGroups = [ "networkmanager" "video" "audio" ];
    shell = pkgs.fish;
    home = "/home/guest";
  };

  # Fixed GIDs for groups (mkForce to override module defaults)
  users.groups.users.gid = 100;
  users.groups.docker.gid = lib.mkForce 998;
  users.groups.podman.gid = lib.mkForce 997;
  users.groups.libvirtd.gid = lib.mkForce 996;
  users.groups.kvm.gid = lib.mkForce 995;

  security.sudo.wheelNeedsPassword = false;

  # Root password (same as diego: 1234567890)
  users.users.root.hashedPassword = "$6$0lk5nosoLlNAcDTp$or4FVVs/Lq1gFMYgjuw6FUdh6dKNE8e/vBClzgik290mxMCzctvN43odeGq7D.qpuJCyyDxJJAsSQNSsB3Vst0";

  # ═══════════════════════════════════════════════════════════════════════════
  # RESCUE MODE (Boot specialisation)
  # ═══════════════════════════════════════════════════════════════════════════
  # Appears in GRUB as "NixOS - Rescue"
  # - No desktop (text mode only)
  # - Auto-login as root on TTY1
  # - WiFi available via nmtui/nmcli
  # - Recovery tools included

  specialisation.rescue.configuration = {
    # Disable graphical interface
    services.xserver.enable = lib.mkForce false;
    services.desktopManager.plasma6.enable = lib.mkForce false;
    services.xserver.desktopManager.gnome.enable = lib.mkForce false;
    services.displayManager.sddm.enable = lib.mkForce false;

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

  # ═══════════════════════════════════════════════════════════════════════════
  # HOME MANAGER (Per-user configuration management)
  # ═══════════════════════════════════════════════════════════════════════════

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";

    users.diego = { pkgs, ... }: {
      home.stateVersion = "24.11";

      # User-specific packages (not system-wide)
      home.packages = with pkgs; [
        # Add user-specific tools here
        htop
      ];

      # Git configuration
      programs.git = {
        enable = true;
        userName = "Diego";
        userEmail = "me@diegonmarcos.com";
      };

      # Fish shell configuration
      programs.fish = {
        enable = true;
        shellAliases = {
          ll = "ls -lah";
          ".." = "cd ..";
        };
        shellInit = ''
          # Add npm global packages to PATH
          set -gx PATH $HOME/.npm-global/bin $PATH
        '';
      };
    };

    users.guest = { pkgs, ... }: {
      home.stateVersion = "24.11";
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SESSION 1: KDE PLASMA 6 (Default)
  # ═══════════════════════════════════════════════════════════════════════════

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    # Virtual keyboard for touchscreen login (Surface Pro)
    settings.General.InputMethod = "qtvirtualkeyboard";
  };
  services.displayManager.defaultSession = "plasma";

  # ═══════════════════════════════════════════════════════════════════════════
  # SESSION 2: GNOME
  # ═══════════════════════════════════════════════════════════════════════════

  services.xserver.desktopManager.gnome.enable = true;
  programs.gnome-terminal.enable = true;

  # Resolve KDE/GNOME askpass conflict
  programs.ssh.askPassword = lib.mkForce "${pkgs.libsForQt5.ksshaskpass}/bin/ksshaskpass";

  # XDG Portal configuration
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-kde
      xdg-desktop-portal-gtk
    ];
    config.common.default = [ "kde" "gtk" ];
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SESSION 3: OPENBOX (X11 Lightweight)
  # ═══════════════════════════════════════════════════════════════════════════

  services.xserver = {
    enable = true;
    xkb.layout = "es";
    xkb.options = "eurosign:e";  # Euro sign with AltGr+E
    windowManager.openbox.enable = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SESSION 4: WAYDROID (Android Container)
  # ═══════════════════════════════════════════════════════════════════════════

  virtualisation.waydroid.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # SSH (Ephemeral host keys - regenerate each boot)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # Host keys regenerate on every boot (stored in tmpfs).
  # This means SSH clients will see "host key changed" warnings.
  # For a Surface tablet used as personal device, this is acceptable.
  # Alternative: persist host keys in @shared/ssh/ via tmpfiles symlink if needed.

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = lib.mkDefault "no";  # ISO installer overrides to "yes"
    };
    # Let NixOS generate ephemeral keys to /etc/ssh (tmpfs)
    # Remove hostKeys to use default ephemeral behavior
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # AUDIO (Pipewire)
  # ═══════════════════════════════════════════════════════════════════════════

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE
  # ═══════════════════════════════════════════════════════════════════════════

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    # Store pairings in @shared (cross-OS)
    settings = {
      General = {
        # Use @shared for bluetooth state
      };
    };
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # PLYMOUTH (Boot Splash)
  # ═══════════════════════════════════════════════════════════════════════════

  boot.plymouth = {
    enable = true;
    theme = "bgrt";
  };

  boot.initrd.kernelModules = [ "i915" ];

  # ═══════════════════════════════════════════════════════════════════════════
  # CONTAINERS (Data in @shared/data/containers/)
  # ═══════════════════════════════════════════════════════════════════════════

  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "btrfs";
      daemon.settings = {
        data-root = "/mnt/shared/data/containers/docker";
      };
    };

    podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    libvirtd.enable = true;
  };

  virtualisation.containers.storage.settings = {
    storage = {
      driver = "btrfs";
      graphroot = "/mnt/shared/data/containers/podman";
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "diego" ];

      # CRITICAL: Use disk-backed build directory, NOT tmpfs
      # Kernel builds need 5-10GB temp space, tmpfs only has ~4GB
      # This prevents "No space left on device" during large builds
      build-dir = "/var/tmp/nix-build";
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SYSTEM PACKAGES - MINIMAL
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ─── Absolute Minimum CLI ───────────────────────────────────────────────
    vim
    fish

    # ─── Bootstrap Tools (CRITICAL - for building user space) ───────────────
    firefox      # Web browser (authenticate, download, research)
    git          # Version control (clone repos, manage dotfiles)
    wget         # Download tool
    curl         # Alternative download tool
    nodejs       # Includes npm, npx (for Claude Code and JS development)

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
  programs.bash.completion.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # FONTS (Minimal set for GUI)
  # ═══════════════════════════════════════════════════════════════════════════

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-emoji
    liberation_ttf
    jetbrains-mono
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # FLATPAK (For user apps)
  # ═══════════════════════════════════════════════════════════════════════════

  services.flatpak.enable = true;

  # Add Flathub remote on boot (tmpfs root requires this)
  systemd.services.flatpak-add-flathub = {
    description = "Add Flathub remote to Flatpak";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Retry up to 3 times with 5 second delay (network may not be ready)
      Restart = "on-failure";
      RestartSec = "5s";
      StartLimitBurst = 3;
      ExecStart = pkgs.writeShellScript "flatpak-add-flathub" ''
        echo "[FLATPAK] Adding Flathub remote..."

        # Check if already configured
        if ${pkgs.flatpak}/bin/flatpak remotes | grep -q flathub; then
          echo "[FLATPAK] Flathub already configured"
          exit 0
        fi

        # Add flathub
        if ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
          echo "[FLATPAK] SUCCESS: Flathub remote added"
        else
          echo "[FLATPAK] ERROR: Failed to add Flathub (exit $?)" >&2
          echo "[FLATPAK] HINT: Check network connectivity" >&2
          exit 1
        fi
      '';
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # CUSTOM SESSION FILES
  # ═══════════════════════════════════════════════════════════════════════════

  # SDDM session directories - ensure custom sessions are found
  # Qt6 virtual keyboard for touchscreen login (Surface Pro with Plasma 6)
  services.displayManager.sddm.extraPackages = with pkgs.kdePackages; [
    qtvirtualkeyboard
  ];
  environment.pathsToLink = [ "/share/wayland-sessions" "/share/xsessions" ];

  environment.etc = {
    # Waydroid session - symlink to standard location for SDDM
    "xdg/wayland-sessions/android.desktop".text = ''
      [Desktop Entry]
      Name=Android (Waydroid)
      Comment=Full Android UI via Waydroid
      Exec=cage -- waydroid show-full-ui
      Type=Application
      DesktopNames=Android
    '';
    # Also put in legacy location
    "wayland-sessions/android.desktop".text = ''
      [Desktop Entry]
      Name=Android (Waydroid)
      Comment=Full Android UI via Waydroid
      Exec=cage -- waydroid show-full-ui
      Type=Application
      DesktopNames=Android
    '';

    "wayland-sessions/tor-kiosk.desktop".text = ''
      [Desktop Entry]
      Name=Tor Kiosk
      Comment=Anonymous browsing
      Exec=cage -- tor-browser
      Type=Application
      DesktopNames=TorKiosk
    '';

    "wayland-sessions/chrome-kiosk.desktop".text = ''
      [Desktop Entry]
      Name=Chrome Kiosk
      Comment=Chromium kiosk mode
      Exec=cage -- chromium --kiosk --start-fullscreen
      Type=Application
      DesktopNames=ChromeKiosk
    '';

    "wayland-sessions/gnome-kiosk.desktop".text = ''
      [Desktop Entry]
      Name=GNOME Kiosk
      Comment=Locked down GNOME session
      Exec=gnome-session --session=gnome
      Type=Application
      DesktopNames=GNOME-Kiosk
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SHARED TOOLS & DATA INTEGRATION
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # @shared/ structure:
  #   tools/      - CLI tools (base, dev, data, devops) + scripts
  #   configs/    - Shared configurations (vpn, app configs)
  #   data/       - Persistent data (cache, containers, vm, fonts, themes)
  #   waydroid/   - Android
  #   mnt/        - External drive mount points
  #

  environment.sessionVariables = {
    # Shared caches (inside data/)
    CARGO_HOME = "/mnt/shared/data/cache/cargo";
    GOPATH = "/mnt/shared/data/cache/go";
    npm_config_cache = "/mnt/shared/data/cache/npm";
    PIP_CACHE_DIR = "/mnt/shared/data/cache/pip";

    # Tools bin directories in PATH
    PATH = [
      "/mnt/shared/tools/base/bin"
      "/mnt/shared/tools/dev/bin"
      "/mnt/shared/tools/data/bin"
      "/mnt/shared/tools/devops/bin"
      "/mnt/shared/tools/scripts"
    ];
  };

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
    "d /mnt/shared/data/containers/docker 0755 root root -"
    "d /mnt/shared/data/containers/podman 0755 root root -"
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
  # PER-USER BLUETOOTH (PAM session hook)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # On login: symlink /var/lib/bluetooth -> ~/.local/share/bluetooth
  # On logout: remove symlink
  # This makes bluetooth pairings portable with the user's home

  # NOTE: Bluetooth portable pairings disabled for now
  # The .text = lib.mkAfter approach REPLACES the entire PAM config instead of appending,
  # which breaks authentication. This needs a different approach (udev rules or systemd service).
  # TODO: Implement bluetooth symlink via systemd user service instead of PAM

  # ═══════════════════════════════════════════════════════════════════════════
  # KEYRING SERVICES (For WiFi passwords)
  # ═══════════════════════════════════════════════════════════════════════════

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.sddm.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # KWallet for KDE sessions
  security.pam.services.sddm.enableKwallet = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # UDEV RULES (Device naming for Dolphin/KDE)
  # ═══════════════════════════════════════════════════════════════════════════

  services.udev.extraRules = ''
    # Set friendly name for btrfs pool in Dolphin/KDE file manager
    # This overrides the default which shows just "home-diego"
    ENV{ID_FS_TYPE}=="btrfs", ENV{ID_FS_LABEL}=="pool", ENV{UDISKS_NAME}="NixOS Pool (btrfs)"
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # ACTIVATION SCRIPTS
  # ═══════════════════════════════════════════════════════════════════════════

  system.activationScripts.updateGrub = ''
    echo "[GRUB] Checking for update script..."
    if [ -x /boot/grub/update-grub.sh ]; then
      if /boot/grub/update-grub.sh; then
        echo "[GRUB] Successfully updated GRUB"
      else
        echo "[GRUB] WARNING: update-grub.sh failed (exit $?)" >&2
      fi
    else
      echo "[GRUB] No update script found (skipping)"
    fi
  '';

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
  # Canonical source: /mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host/
  # Convenient access: /nix/specs/

  system.activationScripts.nixSpecs = ''
    echo "[SPECS] Setting up /nix/specs/..."
    SPECS_SRC="/mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host"

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

      if ! mountpoint -q /mnt/kubuntu 2>/dev/null; then
        echo "[SPECS] HINT: /mnt/kubuntu is not mounted" >&2
      fi

      # Create fallback directory with README
      mkdir -p /nix/specs
      cat > /nix/specs/README.md << 'SPECEOF'
# NixOS Specs - FALLBACK MODE

Configuration source not found at expected location.

## Expected Location
/mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host/

## Troubleshooting

1. Check if Kubuntu partition is mounted:
   mountpoint /mnt/kubuntu

2. Mount it manually:
   sudo mount /mnt/kubuntu

3. Rebuild NixOS to refresh symlink:
   sudo nixos-rebuild switch --flake /mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host#surface

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
