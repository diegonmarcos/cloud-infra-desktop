# NixOS Surface Slim - Ultra-Minimal Recovery Configuration
# Target: ~600-700MB ISO, minimal footprint
#
# Features:
#   - Surface Pro 8 hardware support (linux-surface kernel via nixos-hardware)
#   - Openbox minimal GUI (X11) - NO display manager, use startx
#   - Fish shell with essential CLI tools
#   - Node.js + Claude Code
#   - WiFi GUI (nm-connection-editor)
#   - Auto-login to console, startx for GUI

{ config, pkgs, lib, ... }:

{
  system.stateVersion = "24.11";

  # ═══════════════════════════════════════════════════════════════════════════
  # BOOT - Surface optimized
  # ═══════════════════════════════════════════════════════════════════════════

  boot = {
    # Minimal filesystem support
    supportedFilesystems = [ "btrfs" "ext4" "vfat" "ntfs" ];

    kernelParams = [
      "quiet"
      "mitigations=off"  # Performance on recovery system
    ];

    initrd = {
      compressor = "zstd";
      compressorArgs = [ "-19" "-T0" ];
      supportedFilesystems = [ "btrfs" "ext4" "vfat" ];
      kernelModules = [ "i915" ];  # Intel graphics early
    };

    # Surface kernel modules (Type Cover keyboard CRITICAL)
    kernelModules = [
      "surface_aggregator"
      "surface_aggregator_registry"
      "surface_hid_core"
      "surface_hid"
      "hid_multitouch"
      "8250_dw"
    ];

    blacklistedKernelModules = [ "surfacepro3_button" ];
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # NETWORKING & WIFI
  # ═══════════════════════════════════════════════════════════════════════════

  networking = {
    hostName = "nixos-surface";
    networkmanager = {
      enable = true;
      wifi = {
        backend = "iwd";
        powersave = false;
      };
    };
    wireless.iwd = {
      enable = true;
      settings = {
        General.EnableNetworkConfiguration = false;
        Settings.AutoConnect = true;
      };
    };
    firewall.enable = false;  # Recovery system
  };

  # Surface WiFi firmware
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ pkgs.linux-firmware ];

  # ═══════════════════════════════════════════════════════════════════════════
  # LOCALE - Minimal
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

  users.users.root.initialPassword = "1234567890";
  security.sudo.wheelNeedsPassword = false;

  # ═══════════════════════════════════════════════════════════════════════════
  # DISPLAY - OPENBOX (NO SDDM - use startx)
  # ═══════════════════════════════════════════════════════════════════════════

  services.xserver = {
    enable = true;
    xkb.layout = "us";
    windowManager.openbox.enable = true;
    # NO display manager - boot to console, use startx
    displayManager.startx.enable = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE - Surface specific
  # ═══════════════════════════════════════════════════════════════════════════

  # iptsd for touch/pen/keyboard (CRITICAL for Type Cover)
  services.iptsd.enable = true;

  hardware.graphics.enable = true;

  # NO bluetooth - slimmer image

  # ═══════════════════════════════════════════════════════════════════════════
  # SERVICES - Minimal
  # ═══════════════════════════════════════════════════════════════════════════

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  # Auto-login to console
  services.getty.autologinUser = "diego";

  # NO audio - recovery system doesn't need it
  services.pipewire.enable = false;

  # ═══════════════════════════════════════════════════════════════════════════
  # PACKAGES - ABSOLUTE MINIMUM
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ─── Shells ────────────────────────────────────────────────────────────────
    fish bash

    # ─── Editors ───────────────────────────────────────────────────────────────
    vim nano

    # ─── Network ───────────────────────────────────────────────────────────────
    curl wget git openssh iwd

    # ─── System tools ──────────────────────────────────────────────────────────
    htop btop neofetch
    parted gptfdisk e2fsprogs dosfstools btrfs-progs
    cryptsetup ntfs3g
    pciutils usbutils lsof file tree

    # ─── CLI productivity ──────────────────────────────────────────────────────
    ripgrep fzf jq tmux

    # ─── Development (Claude Code) ─────────────────────────────────────────────
    nodejs_22

    # ─── Openbox GUI (minimal) ─────────────────────────────────────────────────
    sakura              # Terminal
    pcmanfm             # File manager
    dmenu               # Launcher (lighter than rofi)

    # ─── WiFi GUI ──────────────────────────────────────────────────────────────
    networkmanagerapplet  # nm-connection-editor for GUI WiFi config

    # ─── Browser (OAuth for Claude) ────────────────────────────────────────────
    surf                # Minimal webkit browser

    # ─── Fonts (minimal) ───────────────────────────────────────────────────────
    dejavu_fonts

    # ─── X utilities ───────────────────────────────────────────────────────────
    xorg.xsetroot       # Background color
    xorg.xinit          # startx
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # SHELL CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      function fish_greeting
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║     NixOS Surface Recovery           ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  startx    - Start Openbox GUI       ║"
        echo "║  nmtui     - WiFi (terminal)         ║"
        echo "║  claude    - Claude Code CLI         ║"
        echo "║  btop      - System monitor          ║"
        echo "╚══════════════════════════════════════╝"
        echo ""
      end

      alias ll='ls -lah'
      alias la='ls -a'
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # DISABLE FOR SLIM
  # ═══════════════════════════════════════════════════════════════════════════

  documentation = {
    enable = false;
    man.enable = true;
    doc.enable = false;
    info.enable = false;
    nixos.enable = false;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # OPENBOX CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  # Menu (right-click)
  environment.etc."skel/.config/openbox/menu.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_menu xmlns="http://openbox.org/3.4/menu">
    <menu id="root-menu" label="Menu">
      <item label="Terminal"><action name="Execute"><command>sakura</command></action></item>
      <item label="Files"><action name="Execute"><command>pcmanfm</command></action></item>
      <item label="Browser"><action name="Execute"><command>surf https://claude.ai</command></action></item>
      <separator />
      <item label="WiFi Settings"><action name="Execute"><command>nm-connection-editor</command></action></item>
      <item label="WiFi (nmtui)"><action name="Execute"><command>sakura -e nmtui</command></action></item>
      <item label="Claude Code"><action name="Execute"><command>sakura -e claude</command></action></item>
      <item label="System Monitor"><action name="Execute"><command>sakura -e btop</command></action></item>
      <separator />
      <menu id="recovery" label="Recovery">
        <item label="Unlock LUKS"><action name="Execute"><command>sakura -e 'sudo cryptsetup open /dev/nvme0n1p4 pool; read'</command></action></item>
        <item label="Mount Pool"><action name="Execute"><command>sakura -e 'sudo mount /dev/mapper/pool /mnt/pool; read'</command></action></item>
        <item label="Disk Usage"><action name="Execute"><command>sakura -e 'df -h; read'</command></action></item>
      </menu>
      <separator />
      <item label="Reboot"><action name="Execute"><command>systemctl reboot</command></action></item>
      <item label="Shutdown"><action name="Execute"><command>systemctl poweroff</command></action></item>
    </menu>
    </openbox_menu>
  '';

  # Keyboard shortcuts
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
      <keybind key="W-d"><action name="Execute"><command>dmenu_run</command></action></keybind>
      <keybind key="W-w"><action name="Execute"><command>nm-connection-editor</command></action></keybind>
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
      <context name="Maximize"><mousebind button="Left" action="Click"><action name="ToggleMaximize"/></mousebind></context>
      <context name="Client"><mousebind button="Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind></context>
    </mouse>
    <menu><file>menu.xml</file></menu>
    </openbox_config>
  '';

  # Autostart
  environment.etc."skel/.config/openbox/autostart".text = ''
    # Set background color (Nord dark)
    xsetroot -solid "#2e3440" &
  '';

  # xinitrc for startx
  environment.etc."skel/.xinitrc".text = ''
    exec openbox-session
  '';

  # Copy skel to diego home
  system.activationScripts.setupUserConfig = ''
    if [ ! -f /home/diego/.config/openbox/menu.xml ]; then
      mkdir -p /home/diego/.config/openbox
      cp -r /etc/skel/.config/openbox/* /home/diego/.config/openbox/ 2>/dev/null || true
      cp /etc/skel/.xinitrc /home/diego/.xinitrc 2>/dev/null || true
      chown -R diego:users /home/diego/.config /home/diego/.xinitrc 2>/dev/null || true
    fi
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # CLAUDE CODE - npx wrapper
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = lib.mkAfter [
    (pkgs.writeShellScriptBin "claude" ''
      exec ${pkgs.nodejs_22}/bin/npx --yes @anthropic-ai/claude-code "$@"
    '')
  ];
}
