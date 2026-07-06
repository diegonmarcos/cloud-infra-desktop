# Display: SDDM, Plasma 6, GNOME, Openbox, themes, HiDPI, XDG portals, graphics
{ config, pkgs, lib, ... }:

let
  # Unified system wallpaper (declared in cloud-data-wallpaper.json, also
  # consumed by ba_flakes_desktop home-manager flake). Resolved at activation
  # time via /run/current-system/sw which is populated from
  # environment.systemPackages (kdePackages.plasma-workspace-wallpapers).
  wallpaperJson = builtins.fromJSON (builtins.readFile ./cloud-data-wallpaper.json);
  wallpaperPath = "/run/current-system/sw/share/wallpapers/${wallpaperJson.wallpaper.theme}/contents/images/${wallpaperJson.wallpaper.image}";
in

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
Background="${wallpaperPath}"
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

  # XDG Portal configuration moved to configuration_session_isolation.nix
  # (session-aware defaults: KDE portal for Plasma, GNOME portal for GNOME)

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
    # Iris Xe (TigerLake-LP GT2) needs explicit VAAPI + Vulkan packages so Mesa
    # can expose hardware compositing under Wayland. Without these, Brave/
    # Chromium falls back to software compositing — backdrop-filter, blur and
    # paint all run on the CPU, costing ~3.5× more per RasterTask on a 1920px
    # viewport vs a 360px one. brave://gpu showed "Compositing: Software only"
    # + "Failed to find drm render node path" until these landed.
    extraPackages = with pkgs; [
      intel-media-driver  # iHD VAAPI driver for Gen 9+ Intel (Iris Xe)
      libvdpau-va-gl      # VDPAU bridge for legacy VA-API consumers
      vpl-gpu-rt          # Modern Intel media SDK runtime (oneVPL)
      vulkan-loader       # Vulkan ICD loader
      vulkan-validation-layers
    ];
  };

  # LIBVA_DRIVER_NAME=iHD pins Mesa to the modern Intel iHD driver so the
  # browser/video stack picks the right one at startup (Mesa otherwise probes
  # and may pick the legacy i965 driver which doesn't accelerate Iris Xe).
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
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



  # ═══════════════════════════════════════════════════════════════════════════
  # NIX-LD (Dynamic Linker for Unpatched Binaries / Google Antigravity)
  # ═══════════════════════════════════════════════════════════════════════════

  # nix-ld intercepts requests for standard hardcoded interpreter pathways
  # (like /lib64/ld-linux-x86-64.so.2) from unpatched pre-compiled binaries
  # and redirects them to the Nix store. This resolves the sandboxed IPC
  # "Invalid environment block" error encountered in Electron forks like
  # Google Antigravity when running on NixOS.
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      # Core POSIX execution
      glib
      glibc
      zlib
      icu

      # Hardware Acceleration & 3D Graphics (Resolves ANGLE display initialization)
      libglvnd            # Vendor-Neutral Architecture (Provides libEGL.so.1)
      mesa                # Open Source graphics library
      libdrm              # Direct Rendering Manager interfaces

      # Desktop Integration, Inter-process Communication & Cryptography
      xdg-utils           # Desktop handshakes (Allows browser redirection)
      glib-networking     # Network streams & secure tokens
      gsettings-desktop-schemas
      udev                # Device state and monitor scaling hooks
      libsecret           # Secure credential storage mapping
      libnotify           # System tray notifications

      # XML & Vector Layout engines
      expat               # Stream-oriented XML parser
      cairo               # 2D graphics rendering engine
      pango               # Layout and rendering of international text
      gdk-pixbuf          # Image loading and pixel-buffer manipulation

      # Font Subsystem Management (Crucial for Electron UI rendering)
      fontconfig
      freetype

      # Core Electron / Chromium Windowing requirements
      nss                 # Network Security Services
      nspr                # Netscape Portable Runtime
      atk                 # Accessibility Toolkit
      at-spi2-core        # Modern IPC Service Provider for Assistive Tech
      cups                # Common Unix Printing System
      dbus                # D-Bus session bus communication
      gtk3                # GTK window rendering
      alsa-lib            # Sound handler architecture
      libxkbcommon        # XKB keymap parser engine

      # Native X11 Backend Handlers
      xorg.libX11
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXrandr
      xorg.libxcb
    ];
  };
}
