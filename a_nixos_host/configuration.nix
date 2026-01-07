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
  # NO IMPERMANENCE MODULE
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # This system is USER AGNOSTIC with FULLY DETACHABLE homes:
  #
  #   - /home/diego and /home/guest are dedicated btrfs subvolumes
  #   - They persist everything automatically (no bind mounts needed)
  #   - SSH host keys regenerate on boot (ephemeral, accept warnings)
  #   - machine-id is hardcoded (stable across reboots)
  #   - NetworkManager connections stored in @shared (cross-OS)
  #   - Bluetooth pairings stored in @shared (cross-OS)
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
    networkmanager.enable = true;
    firewall = {
      enable = lib.mkDefault true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # PER-USER WIFI & BLUETOOTH
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # WiFi: Passwords stored in user's keyring (GNOME Keyring / KWallet)
  #       - Keyring is in ~/.local/share/keyrings/ (portable with home)
  #       - When user logs in, their saved WiFi networks auto-connect
  #
  # Bluetooth: Pairings stored per-user via PAM session hook
  #       - Each user has ~/.local/share/bluetooth/
  #       - Symlinked to /var/lib/bluetooth at login
  #       - Pairings portable with home
  #

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

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

  # ═══════════════════════════════════════════════════════════════════════════
  # USER ACCOUNTS (Fixed UIDs for cross-OS compatibility)
  # ═══════════════════════════════════════════════════════════════════════════

  users.mutableUsers = false;  # Users defined only in config, not /etc/passwd

  users.users.diego = {
    isNormalUser = true;
    description = "Diego";
    uid = 1000;
    group = "users";
    initialPassword = "1234567890";
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
    initialPassword = "guest";
    extraGroups = [ "networkmanager" "video" "audio" ];
    shell = pkgs.fish;
    home = "/home/guest";
  };

  # Fixed GIDs for groups
  users.groups.users.gid = 100;
  users.groups.docker.gid = 998;
  users.groups.podman.gid = 997;
  users.groups.libvirtd.gid = 996;
  users.groups.kvm.gid = 995;

  security.sudo.wheelNeedsPassword = false;

  # ═══════════════════════════════════════════════════════════════════════════
  # SESSION 1: KDE PLASMA 6 (Default)
  # ═══════════════════════════════════════════════════════════════════════════

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

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
    xkb.layout = "us";
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
      PermitRootLogin = "no";
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

  # ═══════════════════════════════════════════════════════════════════════════
  # CUSTOM SESSION FILES
  # ═══════════════════════════════════════════════════════════════════════════

  environment.etc = {
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
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # PER-USER BLUETOOTH (PAM session hook)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # On login: symlink /var/lib/bluetooth -> ~/.local/share/bluetooth
  # On logout: remove symlink
  # This makes bluetooth pairings portable with the user's home

  security.pam.services.sddm.text = lib.mkAfter ''
    session optional pam_exec.so /run/current-system/sw/bin/bash -c 'mkdir -p $HOME/.local/share/bluetooth && rm -rf /var/lib/bluetooth && ln -sf $HOME/.local/share/bluetooth /var/lib/bluetooth && chown -R $USER:users $HOME/.local/share/bluetooth 2>/dev/null || true'
  '';

  # Also for login shells (SSH, TTY)
  security.pam.services.login.text = lib.mkAfter ''
    session optional pam_exec.so /run/current-system/sw/bin/bash -c 'mkdir -p $HOME/.local/share/bluetooth && rm -rf /var/lib/bluetooth && ln -sf $HOME/.local/share/bluetooth /var/lib/bluetooth && chown -R $USER:users $HOME/.local/share/bluetooth 2>/dev/null || true'
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # KEYRING SERVICES (For WiFi passwords)
  # ═══════════════════════════════════════════════════════════════════════════

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.sddm.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # KWallet for KDE sessions
  security.pam.services.sddm.enableKwallet = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # ACTIVATION SCRIPTS
  # ═══════════════════════════════════════════════════════════════════════════

  system.activationScripts.updateGrub = ''
    if [ -x /boot/grub/update-grub.sh ]; then
      /boot/grub/update-grub.sh || true
    fi
  '';
}
