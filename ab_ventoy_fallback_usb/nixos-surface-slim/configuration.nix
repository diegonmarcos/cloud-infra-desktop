# NixOS Surface Slim - Minimal Recovery Configuration
# Target: ~700MB ISO, comparable to Arch/Debian slim builds
#
# Features:
#   - Surface Pro 8 hardware support (linux-surface kernel)
#   - Openbox minimal GUI (X11)
#   - Fish shell with essential CLI tools
#   - Node.js for Claude Code
#   - Auto-login to console
#   - Boots to RAM option

{ config, pkgs, lib, ... }:

{
  system.stateVersion = "24.11";

  # ═══════════════════════════════════════════════════════════════════════════
  # BOOT
  # ═══════════════════════════════════════════════════════════════════════════

  boot = {
    # Use latest kernel for better Surface support
    kernelPackages = pkgs.linuxPackages_latest;

    # Minimal filesystem support
    supportedFilesystems = [ "btrfs" "ext4" "vfat" "ntfs" ];

    # Surface-specific kernel params
    kernelParams = [
      "quiet"
      "splash"
      "mitigations=off"  # Performance on recovery
    ];

    # Minimal initrd
    initrd = {
      compressor = "zstd";
      compressorArgs = [ "-19" "-T0" ];
      supportedFilesystems = [ "btrfs" "ext4" "vfat" ];
      kernelModules = [ "i915" ];  # Intel graphics early
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # NETWORKING & WIFI
  # ═══════════════════════════════════════════════════════════════════════════

  networking = {
    hostName = "nixos-surface";
    networkmanager = {
      enable = true;
      wifi = {
        backend = "iwd";  # iwd works better on Surface
        powersave = false;  # Disable power save for stability
      };
    };
    wireless.iwd = {
      enable = true;
      settings = {
        General = {
          EnableNetworkConfiguration = false;  # Let NM handle this
        };
        Settings = {
          AutoConnect = true;
        };
      };
    };
    firewall.enable = false;  # Recovery system, no firewall needed
  };

  # Surface WiFi firmware
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = with pkgs; [
    linux-firmware
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # LOCALE
  # ═══════════════════════════════════════════════════════════════════════════

  time.timeZone = "Europe/Madrid";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" ];

  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # USER
  # ═══════════════════════════════════════════════════════════════════════════

  users.users.diego = {
    isNormalUser = true;
    uid = 1000;
    description = "Diego";
    initialPassword = "1234567890";
    extraGroups = [ "wheel" "networkmanager" "video" "input" "audio" ];
    shell = pkgs.fish;
  };

  # Root password for emergency
  users.users.root.initialPassword = "1234567890";

  # Passwordless sudo
  security.sudo.wheelNeedsPassword = false;

  # ═══════════════════════════════════════════════════════════════════════════
  # DISPLAY - SDDM + OPENBOX
  # ═══════════════════════════════════════════════════════════════════════════

  services.xserver = {
    enable = true;
    xkb.layout = "us";

    # Openbox window manager
    windowManager.openbox.enable = true;
  };

  # SDDM display manager (lightweight, touch-friendly)
  services.displayManager.sddm = {
    enable = true;
    theme = "breeze";  # Or use "maldives" for minimal
    settings = {
      Theme = {
        CursorTheme = "breeze_cursors";
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE
  # ═══════════════════════════════════════════════════════════════════════════

  hardware = {
    graphics = {
      enable = true;
      # Skip 32-bit for slimness
    };
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          Enable = "Source,Sink,Media,Socket";
        };
      };
    };
  };

  # Bluetooth service
  services.blueman.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # SURFACE HARDWARE SUPPORT (CRITICAL)
  # ═══════════════════════════════════════════════════════════════════════════
  # The nixos-hardware module provides:
  #   - linux-surface kernel patches
  #   - iptsd (touch/pen daemon) - CRITICAL for Type Cover keyboard
  #   - Surface-specific firmware
  #
  # Without iptsd, the Type Cover keyboard will NOT work!
  # The microsoft-surface-pro-intel module is imported in flake.nix

  # Ensure iptsd service is enabled (touch/pen/keyboard)
  services.iptsd.enable = true;

  # Surface kernel modules for Type Cover
  boot.kernelModules = [
    "surface_aggregator"
    "surface_aggregator_registry"
    "surface_hid_core"
    "surface_hid"
    "hid_multitouch"  # Touchscreen
    "8250_dw"         # Serial (for debugging)
  ];

  # Blacklist conflicting modules
  boot.blacklistedKernelModules = [
    "surfacepro3_button"  # Conflicts with SAM
  ];

  # Surface ACPI settings
  boot.kernelParams = lib.mkAfter [
    "surface_aggregator.debug_events=0"
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # SERVICES
  # ═══════════════════════════════════════════════════════════════════════════

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  # No audio needed for recovery
  sound.enable = false;
  services.pipewire.enable = false;

  # ═══════════════════════════════════════════════════════════════════════════
  # PACKAGES - MINIMAL SET
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ─── Shells ───────────────────────────────────────────────────────────────
    fish bash zsh

    # ─── Editors ──────────────────────────────────────────────────────────────
    vim nano

    # ─── Network ──────────────────────────────────────────────────────────────
    curl wget git openssh iwd wpa_supplicant

    # ─── System tools ─────────────────────────────────────────────────────────
    htop btop neofetch
    parted gptfdisk e2fsprogs dosfstools
    btrfs-progs cryptsetup
    pciutils usbutils lsof file tree

    # ─── Surface-specific tools ───────────────────────────────────────────────
    # surface-control    # If available in nixpkgs
    libwacom            # Pen support

    # ─── Bluetooth tools ──────────────────────────────────────────────────────
    bluez bluez-tools   # CLI bluetooth
    blueman             # GUI bluetooth manager

    # ─── CLI tools ────────────────────────────────────────────────────────────
    ripgrep fd fzf jq tmux eza bat zoxide

    # ─── Development (for Claude Code) ────────────────────────────────────────
    nodejs_22 nodePackages.npm

    # ─── Openbox GUI ──────────────────────────────────────────────────────────
    xterm sakura         # Terminals
    pcmanfm              # File manager
    feh                  # Image viewer / wallpaper
    dmenu rofi           # Launchers
    lxappearance         # GTK theme selector

    # ─── WiFi GUI ─────────────────────────────────────────────────────────────
    networkmanagerapplet # nm-applet for systray
    gnome-keyring        # For WiFi password storage

    # ─── Minimal browser (for OAuth / Claude login) ───────────────────────────
    surf                 # Webkit minimal browser (~2MB)
    # Alternatives if surf doesn't work for OAuth:
    # qutebrowser        # Vim-like browser
    # luakit             # Webkit browser

    # ─── Fonts ────────────────────────────────────────────────────────────────
    dejavu_fonts
    liberation_ttf
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # SHELL CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      # Welcome message
      function fish_greeting
        echo ""
        echo "=================================="
        echo "  NixOS Surface Recovery"
        echo "=================================="
        echo ""
        echo "Commands:"
        echo "  startx     - Start Openbox GUI"
        echo "  nmtui      - WiFi configuration"
        echo "  claude     - Claude Code CLI"
        echo "  btop       - System monitor"
        echo ""
        neofetch --off 2>/dev/null
      end

      # Aliases
      alias ll='eza -la'
      alias la='eza -a'
      alias cat='bat --plain'
    '';
  };

  programs.bash.completion.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # DISABLE UNNECESSARY FOR SLIM
  # ═══════════════════════════════════════════════════════════════════════════

  documentation = {
    enable = false;
    man.enable = true;  # Keep man pages
    doc.enable = false;
    info.enable = false;
    nixos.enable = false;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # OPENBOX CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  environment.etc."skel/.config/openbox/menu.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_menu xmlns="http://openbox.org/3.4/menu">
    <menu id="root-menu" label="Menu">
      <item label="Terminal"><action name="Execute"><command>sakura</command></action></item>
      <item label="Files"><action name="Execute"><command>pcmanfm</command></action></item>
      <item label="Browser"><action name="Execute"><command>surf https://claude.ai</command></action></item>
      <separator />
      <item label="WiFi (nmtui)"><action name="Execute"><command>sakura -e nmtui</command></action></item>
      <item label="Bluetooth"><action name="Execute"><command>blueman-manager</command></action></item>
      <item label="Claude Code"><action name="Execute"><command>sakura -e claude</command></action></item>
      <item label="System Monitor"><action name="Execute"><command>sakura -e btop</command></action></item>
      <separator />
      <menu id="system" label="System">
        <item label="Unlock LUKS Pool"><action name="Execute"><command>sakura -e 'sudo cryptsetup open /dev/nvme0n1p4 pool && sudo mount /dev/mapper/pool /mnt/pool'</command></action></item>
        <item label="Mount Kubuntu"><action name="Execute"><command>sakura -e 'sudo mount /dev/nvme0n1p3 /mnt/kubuntu'</command></action></item>
      </menu>
      <separator />
      <item label="Reboot"><action name="Execute"><command>systemctl reboot</command></action></item>
      <item label="Shutdown"><action name="Execute"><command>systemctl poweroff</command></action></item>
    </menu>
    </openbox_menu>
  '';

  environment.etc."skel/.config/openbox/rc.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_config xmlns="http://openbox.org/3.4/rc">
    <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
    <focus><focusNew>yes</focusNew><followMouse>no</followMouse><focusLast>yes</focusLast></focus>
    <placement><policy>Smart</policy><center>yes</center></placement>
    <theme><name>Clearlooks-3.4</name><titleLayout>NLIMC</titleLayout></theme>
    <desktops><number>1</number><names><name>Desktop</name></names></desktops>
    <keyboard>
      <keybind key="W-Return"><action name="Execute"><command>sakura</command></action></keybind>
      <keybind key="W-e"><action name="Execute"><command>pcmanfm</command></action></keybind>
      <keybind key="W-b"><action name="Execute"><command>surf https://claude.ai</command></action></keybind>
      <keybind key="W-d"><action name="Execute"><command>rofi -show drun</command></action></keybind>
      <keybind key="W-q"><action name="Close"/></keybind>
      <keybind key="A-F4"><action name="Close"/></keybind>
      <keybind key="A-Tab"><action name="NextWindow"/></keybind>
    </keyboard>
    <mouse>
      <context name="Root">
        <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind>
      </context>
      <context name="Titlebar">
        <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
        <mousebind button="Left" action="DoubleClick"><action name="ToggleMaximize"/></mousebind>
      </context>
      <context name="Close"><mousebind button="Left" action="Click"><action name="Close"/></mousebind></context>
      <context name="Client"><mousebind button="Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind></context>
    </mouse>
    <menu><file>menu.xml</file></menu>
    </openbox_config>
  '';

  environment.etc."skel/.config/openbox/autostart".text = ''
    # Set background
    xsetroot -solid "#2e3440" &
  '';

  environment.etc."skel/.xinitrc".text = ''
    exec openbox-session
  '';

  # Copy skel to diego home on activation
  system.activationScripts.setupUserConfig = ''
    if [ ! -f /home/diego/.config/openbox/menu.xml ]; then
      mkdir -p /home/diego/.config/openbox
      cp -r /etc/skel/.config/openbox/* /home/diego/.config/openbox/
      cp /etc/skel/.xinitrc /home/diego/.xinitrc
      chown -R diego:users /home/diego/.config /home/diego/.xinitrc
    fi
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # CLAUDE CODE INSTALLATION
  # ═══════════════════════════════════════════════════════════════════════════
  # Install Claude Code globally via npm on first boot
  # This runs as a systemd service to ensure npm is available

  systemd.services.install-claude-code = {
    description = "Install Claude Code CLI";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.nodejs_22}/bin/npm install -g @anthropic-ai/claude-code || true'";
    };

    # Only run if not already installed
    unitConfig = {
      ConditionPathExists = "!/usr/local/lib/node_modules/@anthropic-ai/claude-code";
    };
  };

  # Also provide a wrapper script in case global install fails
  environment.etc."profile.d/claude-code.sh".text = ''
    # Claude Code wrapper
    if ! command -v claude &>/dev/null; then
      alias claude='npx @anthropic-ai/claude-code'
    fi
  '';
}
