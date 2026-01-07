# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    NIXOS SURFACE PRO 8 - IMPERMANENCE                     ║
# ║                                                                           ║
# ║   Full impermanence: tmpfs root, ephemeral /etc and /var                 ║
# ║   Sessions: KDE Plasma, GNOME, Openbox, Waydroid, Kiosk                  ║
# ║   Containers: Docker (compat) + Podman (rootless)                        ║
# ║                                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:

{
  # System version
  system.stateVersion = "24.11";

  # Allow unfree packages (vscode, etc.)
  nixpkgs.config.allowUnfree = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # IMPERMANENCE - Persistent State Declaration
  # ═══════════════════════════════════════════════════════════════════════════

  environment.persistence."/persist" = {
    hideMounts = true;

    # Directories to persist
    directories = [
      "/var/lib/nixos"           # NixOS state
      "/var/lib/systemd"         # systemd state
      "/var/lib/bluetooth"       # Bluetooth pairings
      "/var/lib/NetworkManager"  # Network connections
      "/var/lib/docker"          # Docker data (if not in @shared)
      "/var/lib/containers"      # Podman data (if not in @shared)
      "/var/log"                 # System logs
      "/etc/NetworkManager/system-connections"  # WiFi passwords
    ];

    # Files to persist
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];

    # User-specific persistence
    users.user = {
      directories = [
        ".config"
        ".local"
        ".cache"
        ".ssh"
        ".gnupg"
        "Documents"
        "Downloads"
        "Projects"
      ];
      files = [
        ".bash_history"
        ".zsh_history"
      ];
    };
  };

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

  # Avahi for mDNS/DNS-SD (local network discovery)
  services.avahi = {
    enable = true;
    nssmdns4 = true;  # Enable NSS mDNS support for .local resolution
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
  # Generate the locale
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "es_ES.UTF-8/UTF-8" ];

  # ═══════════════════════════════════════════════════════════════════════════
  # USER ACCOUNT
  # ═══════════════════════════════════════════════════════════════════════════

  users.users.user = {
    isNormalUser = true;
    description = "Default User";
    uid = 1000;  # Match Kinoite for shared access
    initialPassword = "1234567890";
    extraGroups = [
      "wheel" "networkmanager" "video" "audio"
      "docker" "podman" "kvm" "libvirtd"
    ];
    shell = pkgs.fish;
  };

  # Passwordless sudo
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

  # GNOME Kiosk mode
  programs.gnome-terminal.enable = true;

  # Resolve KDE/GNOME askpass conflict - use KDE's
  programs.ssh.askPassword = lib.mkForce "${pkgs.libsForQt5.ksshaskpass}/bin/ksshaskpass";

  # XDG Portal configuration - handle KDE/GNOME coexistence
  xdg.portal = {
    enable = true;
    # KDE portal as default, GNOME as fallback
    extraPortals = with pkgs; [
      xdg-desktop-portal-kde
      xdg-desktop-portal-gtk
    ];
    # Prefer KDE portal for most things when in Plasma
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
  # SSH
  # ═══════════════════════════════════════════════════════════════════════════

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
    };
    hostKeys = [
      { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
      { path = "/persist/etc/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
    ];
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
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # PLYMOUTH (Boot Splash with Touch Keyboard Fallback)
  # ═══════════════════════════════════════════════════════════════════════════
  # If Type Cover keyboard fails, Plymouth provides a touch-friendly
  # password entry screen that works with the Surface touchscreen.
  # FALLBACK: USB keyboard always works as last resort.

  boot.plymouth = {
    enable = true;
    # Use a theme that works well with touch input
    theme = "bgrt";  # Uses OEM logo, simple and reliable
  };

  # Enable early KMS for Plymouth to work with LUKS
  boot.initrd.kernelModules = [ "i915" ];  # Intel graphics early init

  # ═══════════════════════════════════════════════════════════════════════════
  # CONTAINERS (Docker + Podman)
  # ═══════════════════════════════════════════════════════════════════════════

  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "btrfs";
      # Use shared storage
      daemon.settings = {
        data-root = "/mnt/shared/containers/docker";
      };
    };

    podman = {
      enable = true;
      dockerCompat = false;  # Keep docker separate
      defaultNetwork.settings.dns_enabled = true;
    };

    libvirtd.enable = true;
  };

  # Podman storage configuration - use shared location
  virtualisation.containers.storage.settings = {
    storage = {
      driver = "btrfs";
      graphroot = "/mnt/shared/containers/podman";
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "user" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SYSTEM PACKAGES
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ─── Core CLI ────────────────────────────────────────────────────────────
    vim neovim git curl wget htop btop tree jq yq fd ripgrep fzf
    tmux screen zoxide starship eza bat file unzip p7zip pv

    # ─── System tools ────────────────────────────────────────────────────────
    pciutils usbutils lsof parted btrfs-progs cryptsetup

    # ─── Network ─────────────────────────────────────────────────────────────
    nmap dig tcpdump iproute2 wireguard-tools
    nssmdns  # mDNS/DNS-SD support for Avahi

    # ─── Development ─────────────────────────────────────────────────────────
    gcc gnumake cmake
    python3 python312Packages.pip
    nodejs_22 nodePackages.npm
    rustc cargo
    # go           # REMOVED: saves ~250M
    # google-cloud-sdk  # REMOVED: saves ~330M

    # ─── Containers ──────────────────────────────────────────────────────────
    docker-compose podman-compose buildah skopeo dive

    # ─── Desktop apps ────────────────────────────────────────────────────────
    firefox chromium tor-browser
    kate konsole dolphin
    vscode

    # ─── GNOME apps ──────────────────────────────────────────────────────────
    gnome-tweaks gnome-shell-extensions

    # ─── Openbox session ─────────────────────────────────────────────────────
    openbox obconf polybar nitrogen feh rofi dunst picom xterm

    # ─── Wayland kiosk ───────────────────────────────────────────────────────
    cage wlr-randr

    # ─── VM tools ────────────────────────────────────────────────────────────
    virt-manager virt-viewer qemu OVMF

    # ─── Utilities ───────────────────────────────────────────────────────────
    zenity kdialog
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # SHELLS
  # ═══════════════════════════════════════════════════════════════════════════

  programs.fish.enable = true;
  programs.bash.completion.enable = true;

  programs.git = {
    enable = true;
    config.init.defaultBranch = "main";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # FONTS
  # ═══════════════════════════════════════════════════════════════════════════

  fonts.packages = with pkgs; [
    noto-fonts noto-fonts-cjk-sans noto-fonts-emoji
    liberation_ttf fira-code fira-code-symbols jetbrains-mono
    (nerdfonts.override { fonts = [ "FiraCode" "JetBrainsMono" ]; })
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # FLATPAK
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

    # GNOME Kiosk session
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
  # GRUB UPDATE HOOK
  # ═══════════════════════════════════════════════════════════════════════════

  # Script to update GRUB when kernel changes
  system.activationScripts.updateGrub = ''
    if [ -x /boot/grub/update-grub.sh ]; then
      /boot/grub/update-grub.sh || true
    fi
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # FIX HOME DIRECTORY PERMISSIONS
  # ═══════════════════════════════════════════════════════════════════════════
  # Ensure user home directory has correct ownership
  # The impermanence module creates dirs as root, this fixes ownership
  system.activationScripts.fixHomePermissions = lib.stringAfter [ "users" ] ''
    if [ -d /home/user ]; then
      chown -R 1000:1000 /home/user
    fi
  '';
}
