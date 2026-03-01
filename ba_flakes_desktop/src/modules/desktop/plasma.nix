# KDE Plasma configuration - FULL NIX CONTROL
# Requires plasma-manager input in flake.nix
{ config, pkgs, lib, ... }:

{
  # Fix system tray visibility after home-manager switch
  # Plasma reads shownItems from the PRIVATE systemtray containment, not the applet
  home.activation.fixSystemTray = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    APPLETS_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPLETS_FILE" ]; then
      ALL_ITEMS="org.kde.plasma.battery,org.kde.plasma.bluetooth,org.kde.plasma.brightness,org.kde.plasma.networkmanagement,org.kde.plasma.volume,org.kde.plasma.clipboard,org.kde.plasma.devicenotifier,org.kde.plasma.notifications,org.kde.kdeconnect,org.kde.kscreen,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.cameraindicator,org.kde.plasma.manage-inputmethod,org.kde.plasma.mediacontroller"

      # Find the PRIVATE systemtray containment ID (plugin=org.kde.plasma.private.systemtray)
      TRAY_ID=$(${pkgs.gawk}/bin/awk '
        /^\[Containments\]\[[0-9]+\]$/ { current_id = gensub(/.*\[([0-9]+)\]$/, "\\1", "g") }
        /^plugin=org\.kde\.plasma\.private\.systemtray$/ { print current_id; exit }
      ' "$APPLETS_FILE")

      if [ -n "$TRAY_ID" ]; then
        GENERAL_SECTION="[Containments][$TRAY_ID][General]"

        # Check if [General] section exists for this containment
        if grep -qF "$GENERAL_SECTION" "$APPLETS_FILE"; then
          # Remove existing shownItems/hiddenItems in this section
          ${pkgs.gnused}/bin/sed -i "/^\[Containments\]\[$TRAY_ID\]\[General\]$/,/^\[/ {
            /^shownItems=/d
            /^hiddenItems=/d
          }" "$APPLETS_FILE"
          # Add shownItems and hiddenItems after the section header
          ${pkgs.gnused}/bin/sed -i "/^\[Containments\]\[$TRAY_ID\]\[General\]$/a shownItems=$ALL_ITEMS\nhiddenItems=" "$APPLETS_FILE"
        else
          # Section doesn't exist, append it at end of file
          echo "" >> "$APPLETS_FILE"
          echo "$GENERAL_SECTION" >> "$APPLETS_FILE"
          echo "shownItems=$ALL_ITEMS" >> "$APPLETS_FILE"
          echo "hiddenItems=" >> "$APPLETS_FILE"
        fi
      fi
    fi
  '';

  # Configure battery widget to show percentage instead of icon
  home.activation.fixBatteryPercentage = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    APPLETS_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPLETS_FILE" ]; then
      # Find the battery applet section: [Containments][X][Applets][Y] where plugin=org.kde.plasma.battery
      BATTERY_SECTION=$(${pkgs.gawk}/bin/awk '
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ { section = $0 }
        /^plugin=org\.kde\.plasma\.battery$/ { gsub(/\[|\]/, " ", section); split(section, a); printf "[Containments][%s][Applets][%s]", a[2], a[4]; exit }
      ' "$APPLETS_FILE")

      if [ -n "$BATTERY_SECTION" ]; then
        CONFIG_SECTION="$BATTERY_SECTION[Configuration][General]"

        # Check if Configuration/General section exists
        if grep -qF "$CONFIG_SECTION" "$APPLETS_FILE"; then
          # Update existing showPercentage
          ${pkgs.gnused}/bin/sed -i "s/^showPercentage=.*/showPercentage=true/" "$APPLETS_FILE"
          # Add if not present
          if ! grep -q "^showPercentage=" "$APPLETS_FILE"; then
            ${pkgs.gnused}/bin/sed -i "/^$(echo "$CONFIG_SECTION" | ${pkgs.gnused}/bin/sed 's/\[/\\[/g; s/\]/\\]/g')$/a showPercentage=true" "$APPLETS_FILE"
          fi
        else
          # Section doesn't exist, append it
          echo "" >> "$APPLETS_FILE"
          echo "$CONFIG_SECTION" >> "$APPLETS_FILE"
          echo "showPercentage=true" >> "$APPLETS_FILE"
        fi
      fi
    fi
  '';

  programs.plasma = {
    enable = true;

    # ─────────────────────────────────────────────────────────────────
    # Appearance - FULL DARK THEME
    # ─────────────────────────────────────────────────────────────────
    workspace = {
      theme = "breeze-dark";
      colorScheme = "BreezeDark";
      cursor.theme = "breeze_cursors";
      iconTheme = "breeze-dark";
      lookAndFeel = "org.kde.breezedark.desktop";
      wallpaper = "/home/diego/Pictures/Wallpapers/buddha-wallpaper.jpg";
    };

    # Window decorations - Dark
    kwin.titlebarButtons = {
      left = [ "on-all-desktops" "keep-above-windows" ];
      right = [ "minimize" "maximize" "close" ];
    };

    # Fonts
    fonts = {
      general = {
        family = "Noto Sans";
        pointSize = 10;
      };
      fixedWidth = {
        family = "JetBrains Mono";
        pointSize = 10;
      };
    };

    # ─────────────────────────────────────────────────────────────────
    # Keyboard Shortcuts
    # ─────────────────────────────────────────────────────────────────
    shortcuts = {
      kwin = {
        "Window Close" = "Alt+F4";
        "Window Maximize" = "Meta+Up";
        "Window Minimize" = "Meta+Down";
        "Switch to Desktop 1" = "Meta+1";
        "Switch to Desktop 2" = "Meta+2";
        "Switch to Desktop 3" = "Meta+3";
        "Switch to Desktop 4" = "Meta+4";
        "Switch to Previous Desktop" = "Meta+Ctrl+Left";
        "Switch to Next Desktop" = "Meta+Ctrl+Right";
        "Window to Desktop 1" = "Meta+Shift+1";
        "Window to Desktop 2" = "Meta+Shift+2";
        "Window to Desktop 3" = "Meta+Shift+3";
        "Window to Desktop 4" = "Meta+Shift+4";
      };
      plasmashell = {
        "show-on-mouse-pos" = "Meta+V";
      };
      "org.kde.konsole.desktop"."_launch" = "Meta+Return";
      "org.kde.dolphin.desktop"."_launch" = "Meta+E";
    };

    # ─────────────────────────────────────────────────────────────────
    # Window Manager (KWin)
    # ─────────────────────────────────────────────────────────────────
    kwin = {
      effects.shakeCursor.enable = true;
      virtualDesktops = {
        number = 4;
        rows = 1;
        names = [ "Desktop 1" "Desktop 2" "Desktop 3" "Desktop 4" ];
      };

      # Night Light always on (2200K warm)
      nightLight = {
        enable = true;
        mode = "constant";
        temperature = {
          day = 2200;
          night = 2200;
        };
      };
    };

    # Window rules for autostart positioning
    # Screen: 2880x1920 @ 1.25 scale = 2304x1536 effective
    # Left half (1152px): 2 Konsoles stacked (768px each)
    # Right half (1152px): Dolphin full height
    window-rules = [
      {
        description = "Konsole Top - Top Left";
        match = {
          window-class = {
            value = "konsole";
            type = "substring";
          };
          title = {
            value = "Konsole Top";
            type = "substring";
          };
        };
        apply = {
          position = {
            value = "0,0";
            apply = "initially";
          };
          size = {
            value = "1152,768";
            apply = "initially";
          };
        };
      }
      {
        description = "Konsole Bottom - Bottom Left";
        match = {
          window-class = {
            value = "konsole";
            type = "substring";
          };
          title = {
            value = "Konsole Bottom";
            type = "substring";
          };
        };
        apply = {
          position = {
            value = "0,768";
            apply = "initially";
          };
          size = {
            value = "1152,768";
            apply = "initially";
          };
        };
      }
      {
        description = "Dolphin - Right Half";
        match = {
          window-class = {
            value = "dolphin";
            type = "substring";
          };
        };
        apply = {
          position = {
            value = "1152,0";
            apply = "initially";
          };
          size = {
            value = "1152,1536";
            apply = "initially";
          };
        };
      }
    ];

    # ─────────────────────────────────────────────────────────────────
    # Startup script (runs once when config changes)
    # For every-login startup, use xdg.configFile autostart below
    # ─────────────────────────────────────────────────────────────────

    # ─────────────────────────────────────────────────────────────────
    # Panel Configuration - DISABLED (User-managed)
    # ─────────────────────────────────────────────────────────────────
    # IMPORTANT: panels section is DISABLED because it recreates panels
    # on every home-manager switch, which:
    #   1. Assigns new containment IDs each time
    #   2. Loses manually added widgets
    #   3. Breaks configFile entries that reference old IDs
    #
    # Panel layout is now managed manually via KDE System Settings.
    # Your panel configuration persists in:
    #   ~/.config/plasma-org.kde.plasma.desktop-appletsrc
    #
    # ═══════════════════════════════════════════════════════════════
    # CURRENT PANEL LAYOUT (Updated: 2026-02-01)
    # ═══════════════════════════════════════════════════════════════
    # Bottom panel, height 44, no hiding, not floating
    #
    # Widgets (left to right):
    #   - Kickoff (icon: nix-snowflake-white)
    #   - Pager (show desktop numbers)
    #   - Margins Separator
    #   - Icon Tasks (Dolphin, Konsole, Obsidian, Brave, Waydroid, Settings)
    #   - Panel Spacer
    #   - System Monitors:
    #       • CPU (org.kde.plasma.systemmonitor.cpu)
    #       • CPU Core (org.kde.plasma.systemmonitor.cpucore)
    #       • Memory (org.kde.plasma.systemmonitor.memory)
    #       • Disk Usage (org.kde.plasma.systemmonitor.diskusage)
    #       • Disk Activity (org.kde.plasma.systemmonitor.diskactivity)
    #       • Network (org.kde.plasma.systemmonitor.net)
    #   - Margins Separator
    #   - Weather (org.kde.plasma.weather)
    #   - System Tray (all items visible)
    #   - Digital Clock (24h, dd-MM-yyyy below time, Monday first)
    #   - User Switcher
    # ═══════════════════════════════════════════════════════════════

    # ─────────────────────────────────────────────────────────────────
    # KDE Config Files (via configFile - non-destructive merge)
    # ─────────────────────────────────────────────────────────────────
    configFile = {
      # NOTE: Panel/widget containment IDs (like 244, 308) are NOT configured here
      # because Plasma assigns dynamic IDs. Panel config is user-managed.
      # The activation script (fixSystemTray) handles system tray visibility dynamically.

      # Mouse/Touchpad settings
      "kcminputrc"."Libinput.1267.12693.ELAN0732:00 04F3:3195 Touchpad" = {
        NaturalScroll = true;
        TapToClick = true;
      };
      "kcminputrc"."Mouse" = {
        cursorSize = 24;
      };

      # Full Breeze Dark Color Scheme
      "kdeglobals"."ColorEffects:Disabled" = {
        Color = "56,56,56";
        ColorAmount = 0;
        ColorEffect = 0;
        ContrastAmount = "0.65";
        ContrastEffect = 1;
        IntensityAmount = "0.1";
        IntensityEffect = 2;
      };
      "kdeglobals"."ColorEffects:Inactive" = {
        ChangeSelectionColor = true;
        Color = "112,111,110";
        ColorAmount = "0.025";
        ColorEffect = 2;
        ContrastAmount = "0.1";
        ContrastEffect = 2;
        Enable = false;
        IntensityAmount = 0;
        IntensityEffect = 0;
      };
      "kdeglobals"."Colors:Button" = {
        BackgroundAlternate = "30,87,116";
        BackgroundNormal = "49,54,59";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Complementary" = {
        BackgroundAlternate = "30,87,116";
        BackgroundNormal = "42,46,50";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Header" = {
        BackgroundAlternate = "42,46,50";
        BackgroundNormal = "49,54,59";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Header][Inactive" = {
        BackgroundAlternate = "49,54,59";
        BackgroundNormal = "42,46,50";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Selection" = {
        BackgroundAlternate = "30,87,116";
        BackgroundNormal = "61,174,233";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "252,252,252";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "253,188,75";
        ForegroundNegative = "176,55,69";
        ForegroundNeutral = "198,92,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "23,104,57";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Tooltip" = {
        BackgroundAlternate = "42,46,50";
        BackgroundNormal = "49,54,59";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:View" = {
        BackgroundAlternate = "35,38,41";
        BackgroundNormal = "27,30,32";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Window" = {
        BackgroundAlternate = "49,54,59";
        BackgroundNormal = "42,46,50";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."General" = {
        ColorSchemeHash = "babca25f3a5cf7ece26a85de212ab43d0a141257";
        ColorScheme = "BreezeDark";
        TerminalApplication = "konsole";
        TerminalService = "org.kde.konsole.desktop";
      };
      "kdeglobals"."Icons" = {
        Theme = "breeze-dark";
      };
      "kdeglobals"."KDE" = {
        LookAndFeelPackage = "org.kde.breezedark.desktop";
      };

      # Dolphin - Terminal integration
      "dolphinrc"."General" = {
        ShowFullPath = true;
        ShowFullPathInTitlebar = true;
      };
      "dolphinrc"."VersionControl" = {
        enabledPlugins = "Git";
      };

      # Terminal panel config - uses konsolepart KPart plugin
      "dolphinrc"."Terminal Panel" = {
        ShowTerminal = true;
      };

      # Disable session restore (prevents duplicate windows on login)
      "ksmserverrc"."General" = {
        loginMode = "emptySession";
      };

      # ─────────────────────────────────────────────────────────────────
      # KWin Desktop Effects
      # ─────────────────────────────────────────────────────────────────
      "kwinrc"."Plugins" = {
        cubeEnabled = true;
        cubeslideEnabled = true;
        diminactiveEnabled = true;
        wobblywindowsEnabled = true;
        translucencyEnabled = true;
      };

      # Cube effect settings
      "kwinrc"."Effect-cube" = {
        BorderActivate = 9;  # No border activation
        TouchBorderActivate = 9;
      };

      # Dim inactive settings (how much to dim)
      "kwinrc"."Effect-diminactive" = {
        Strength = 15;  # 15% dimming
      };

      # Wobbly windows settings
      "kwinrc"."Effect-wobblywindows" = {
        Drag = 85;
        Stiffness = 10;
        WobblynessLevel = 1;
      };

      # Translucency settings (moving/resizing windows)
      "kwinrc"."Effect-translucency" = {
        MoveResize = 80;  # 80% opacity when moving
      };

      # Virtual keyboard (for Surface touchscreen)
      "kwinrc"."Wayland" = {
        VirtualKeyboard = true;
        "InputMethod[$e]" = "/run/current-system/sw/share/applications/com.github.nickvyni.maliit-keyboard.desktop";
      };

      # Lock screen virtual keyboard
      "kscreenlockerrc"."Greeter" = {
        VirtualKeyboard = true;
        VirtualKeyboardTheme = "breeze";
      };

      # ─────────────────────────────────────────────────────────────────
      # Power Management - Lock on lid close instead of suspend
      # Surface Pro 8 suspend/resume is broken: surface_hid reprobe fails,
      # DRM atomic commit errors, and logind marks the session Active=no,
      # which causes kscreenlocker to silently ignore correct passwords.
      # ─────────────────────────────────────────────────────────────────
      "powerdevilrc"."AC][HandleButtonEvents" = {
        lidAction = 64;  # Lock Screen
      };
      "powerdevilrc"."Battery][HandleButtonEvents" = {
        lidAction = 64;  # Lock Screen
      };
      "powerdevilrc"."LowBattery][HandleButtonEvents" = {
        lidAction = 64;  # Lock Screen
      };

      # Keyboard layouts - Spanish (default), British, Portuguese, German
      "kxkbrc"."Layout" = {
        LayoutList = "es,gb,pt,de";
        DisplayNames = "Spanish,British,Portuguese,German";
        Options = "grp:alt_shift_toggle";  # Switch layouts with Alt+Shift
        ResetOldOptions = true;
        SwitchMode = "Global";
        Use = true;
        VariantList = ",,,";  # Default variants for each layout
      };

      "kdeglobals"."WM" = {
        activeBackground = "49,54,59";
        activeBlend = "252,252,252";
        activeForeground = "252,252,252";
        inactiveBackground = "42,46,50";
        inactiveBlend = "161,169,177";
        inactiveForeground = "161,169,177";
      };
    };
  };

  # ─────────────────────────────────────────────────────────────────
  # Disable xembedsniproxy - causes mouse click freeze on Surface
  # ─────────────────────────────────────────────────────────────────
  # xembedsniproxy handles legacy X11 system tray icons but has a bug
  # that blocks mouse button events intermittently on Wayland/Surface.
  # Modern apps use StatusNotifierItem and don't need this.
  systemd.user.services.plasma-xembedsniproxy = {
    Unit.Description = "Disabled - causes mouse click freeze";
    Service.ExecStart = "${pkgs.coreutils}/bin/true";
    Install.WantedBy = lib.mkForce [];
  };

  # ─────────────────────────────────────────────────────────────────
  # GTK Apps in Plasma
  # ─────────────────────────────────────────────────────────────────
  gtk = {
    enable = true;
    theme = {
      name = "Breeze-Dark";
      package = pkgs.kdePackages.breeze-gtk;
    };
    iconTheme = {
      name = "breeze-dark";
      package = pkgs.kdePackages.breeze-icons;
    };
    cursorTheme = {
      name = "breeze_cursors";
      package = pkgs.kdePackages.breeze;
    };
  };

  # ─────────────────────────────────────────────────────────────────
  # Custom Desktop Entries
  # ─────────────────────────────────────────────────────────────────
  xdg.desktopEntries.waydroid = {
    name = "Waydroid";
    comment = "Android in a container";
    exec = "waydroid-launch";
    icon = "waydroid";
    terminal = false;
    categories = [ "System" "Emulator" ];
  };

  # ─────────────────────────────────────────────────────────────────
  # Autostart - Runs every login
  # ─────────────────────────────────────────────────────────────────
  xdg.configFile."autostart/launch-workspace.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Launch Workspace
    Comment=Open 2 Konsoles (left) and Dolphin (right) on startup
    Exec=sh -c "sleep 3 && kstart --geometry 1152x768+0+0 konsole --title 'Konsole Top' & sleep 0.5 && kstart --geometry 1152x768+0+768 konsole --title 'Konsole Bottom' & sleep 0.5 && kstart --geometry 1152x1536+1152+0 dolphin ~"
    X-KDE-autostart-phase=2
    X-GNOME-Autostart-enabled=true
  '';

  # Fix system tray showAllItems (plasma-manager writes to applet, but Plasma reads from containment)
  # DISABLED: The kquitapp6/kstart plasmashell combo causes GUI freezes 8 seconds after every login.
  # The activation script (fixSystemTray) handles this during home-manager switch instead.
  # If you need to fix system tray visibility, run manually:
  #   kquitapp6 plasmashell && kstart plasmashell
  #
  # xdg.configFile."autostart/fix-systray-showall.desktop".text = ''
  #   [Desktop Entry]
  #   Type=Application
  #   Name=Fix System Tray ShowAll
  #   Exec=sh -c 'sleep 8; CONFIG="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"; ...'
  #   X-KDE-autostart-phase=2
  #   OnlyShowIn=KDE;
  # '';
}
