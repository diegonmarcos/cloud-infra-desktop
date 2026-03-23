# Display: SDDM, Plasma 6, GNOME, Openbox, themes, HiDPI, XDG portals, graphics
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # NOTE: Home-manager is managed separately in cb_user_diego_nix
  # This flake is SYSTEM ONLY - no per-user configuration here
  # ═══════════════════════════════════════════════════════════════════════════

  # ═══════════════════════════════════════════════════════════════════════════
  # SESSION 1: KDE PLASMA 6 (Default)
  # ═══════════════════════════════════════════════════════════════════════════

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "sddm-astronaut-theme";
    extraPackages = with pkgs; [
      kdePackages.qtvirtualkeyboard
      sddm-astronaut-custom
    ];
    settings = {
      General.InputMethod = "qtvirtualkeyboard";
      Theme = {
        EnableAvatars = true;
        CursorTheme = "breeze_cursors";
        CursorSize = 24;
      };
      Users = {
        MaximumUid = 60000;
        MinimumUid = 1000;
      };
      # Scale 125% for Surface Pro HiDPI
      Wayland = {
        EnableHiDPI = true;
      };
      X11 = {
        EnableHiDPI = true;
        ServerArguments = "-nolisten tcp -dpi 120";
      };
    };
  };

  # Global dark theme for ALL apps (Qt + GTK)
  environment.variables = {
    QT_QPA_PLATFORMTHEME = "kde";
    GTK_THEME = "Breeze-Dark";
  };

  # Onboard virtual keyboard - appears in KDE Virtual Keyboard settings
  # This creates a .desktop file that KDE recognizes as a virtual keyboard option
  environment.etc."xdg/applications/org.onboard.Onboard-VirtualKeyboard.desktop".text = ''
    [Desktop Entry]
    Name=Onboard (Full Keyboard)
    Comment=Virtual keyboard with Fn keys, arrows, and mouse buttons
    Exec=onboard
    Type=Application
    X-KDE-Wayland-VirtualKeyboard=true
    Icon=onboard
    NoDisplay=true
  '';

  # Force 125% scaling for SDDM + Virtual Keyboard QML path
  environment.etc."sddm.conf.d/hidpi.conf".text = ''
    [General]
    GreeterEnvironment=QT_SCREEN_SCALE_FACTORS=1.25,QT_FONT_DPI=120,QT_IM_MODULE=qtvirtualkeyboard,QML2_IMPORT_PATH=${pkgs.kdePackages.qtvirtualkeyboard}/lib/qt-6/qml
  '';

  # Custom SDDM Astronaut theme with glassmorphism + mountain background
  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      sddm-astronaut-custom = prev.sddm-astronaut.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          cat > $out/share/sddm/themes/sddm-astronaut-theme/theme.conf << 'EOF'
[General]
Background="/run/current-system/sw/share/wallpapers/MilkyWay/contents/images/5120x2880.png"
DimBackgroundImage="0.2"
ScaleImageCropped="true"
ScreenWidth="2304"
ScreenHeight="1536"
FullBlur="false"
PartialBlur="true"
BlurRadius="100"
HaveFormBackground="true"
FormPosition="center"
MainColor="#ffffff"
AccentColor="#3daee9"
BackgroundColor="#1a1a2e"
placeholderColor="#aaaaaa"
IconColor="#ffffff"
RoundCorners="20"
InterfaceShadowSize="6"
InterfaceShadowOpacity="0.6"
ScreenPadding="0"
Font="Noto Sans"
HideLoginButton="false"
ForceLastUser="true"
ForcePasswordFocus="true"
ForceHideCompletePassword="true"
ForceHideVirtualKeyboardButton="false"
HeaderText="NixOS Surface"
HourFormat="HH:mm"
DateFormat="dddd d MMMM"
EOF
        '';
      });
    })
  ];
  # Default session set in sessions.nix (01-plasma)

  # Disable Plasma Discover update notifier (auto-starts and checks for updates)
  environment.etc."xdg/autostart/org.kde.discover.notifier.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';

  # ─── Openbox autostart (only in Openbox session, not Plasma/GNOME) ────────
  environment.etc."xdg/openbox/autostart".text = ''
    # Compositor
    picom &
    # Panel
    polybar &
    # Wallpaper
    nitrogen --restore &
    # Notifications
    dunst &
    # Terminal on startup
    xterm &
  '';

  # Openbox right-click menu
  environment.etc."xdg/openbox/menu.xml".text = ''
    <?xml version="1.0" encoding="utf-8"?>
    <openbox_menu xmlns="http://openbox.org/3.4/menu">
      <menu id="root-menu" label="Menu">
        <item label="Terminal"><action name="Execute"><command>xterm</command></action></item>
        <item label="File Manager"><action name="Execute"><command>dolphin</command></action></item>
        <item label="Firefox"><action name="Execute"><command>firefox</command></action></item>
        <item label="Brave"><action name="Execute"><command>brave</command></action></item>
        <separator/>
        <item label="Rofi Launcher"><action name="Execute"><command>rofi -show drun</command></action></item>
        <separator/>
        <item label="Reconfigure"><action name="Reconfigure"/></item>
        <item label="Log Out"><action name="Exit"/></item>
      </menu>
    </openbox_menu>
  '';

  # Openbox keybinds
  environment.etc."xdg/openbox/rc.xml".text = ''
    <?xml version="1.0" encoding="utf-8"?>
    <openbox_config xmlns="http://openbox.org/3.4/rc">
      <keyboard>
        <keybind key="A-Return"><action name="Execute"><command>xterm</command></action></keybind>
        <keybind key="A-d"><action name="Execute"><command>rofi -show drun</command></action></keybind>
        <keybind key="A-F4"><action name="Close"/></keybind>
        <keybind key="A-Tab"><action name="NextWindow"/></keybind>
        <keybind key="A-F11"><action name="ToggleFullscreen"/></keybind>
        <keybind key="A-Left"><action name="UnmaximizeFull"/><action name="MoveResizeTo"><x>0</x><y>0</y><width>50%</width><height>100%</height></action></keybind>
        <keybind key="A-Right"><action name="UnmaximizeFull"/><action name="MoveResizeTo"><x>50%</x><y>0</y><width>50%</width><height>100%</height></action></keybind>
      </keyboard>
      <mouse>
        <context name="Frame">
          <mousebind button="A-Left" action="Drag"><action name="Move"/></mousebind>
          <mousebind button="A-Right" action="Drag"><action name="Resize"/></mousebind>
        </context>
      </mouse>
      <applications/>
    </openbox_config>
  '';

  # Picom: X11 compositor - only run in Openbox session (not Wayland)
  environment.etc."xdg/autostart/picom.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=picom
    Exec=picom
    OnlyShowIn=OPENBOX;
  '';

  # NOTE: System tray fix moved to home-manager (plasma-manager workaround)

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
  # HARDWARE (Display-related)
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
  # CUSTOM SESSION FILES
  # ═══════════════════════════════════════════════════════════════════════════

  # SDDM session directories - ensure custom sessions are found
  environment.pathsToLink = [ "/share/wayland-sessions" "/share/xsessions" ];

  # Custom SDDM sessions defined in ./sessions.nix (proper Nix module)
}
