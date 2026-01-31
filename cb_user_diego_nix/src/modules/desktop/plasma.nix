# KDE Plasma configuration - FULL NIX CONTROL
# Requires plasma-manager input in flake.nix
{ config, pkgs, lib, ... }:

{
  # Fix system tray visibility after home-manager switch
  # This is needed because plasma-manager's configFile uses dot notation
  # which KDE doesn't recognize for bracket-notation sections
  home.activation.fixSystemTray = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    APPLETS_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPLETS_FILE" ]; then
      # All items that should be shown
      ALL_ITEMS="org.kde.plasma.battery,org.kde.plasma.bluetooth,org.kde.plasma.brightness,org.kde.plasma.networkmanagement,org.kde.plasma.volume,org.kde.plasma.clipboard,org.kde.plasma.devicenotifier,org.kde.plasma.notifications,org.kde.kdeconnect,org.kde.kscreen,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.cameraindicator,org.kde.plasma.manage-inputmethod,org.kde.plasma.mediacontroller"

      # Find the private systemtray containment ID by looking for the plugin line
      TRAY_ID=$(grep -B20 "plugin=org.kde.plasma.private.systemtray" "$APPLETS_FILE" | grep -oP '(?<=\[Containments\]\[)[0-9]+(?=\])' | tail -1)

      if [ -n "$TRAY_ID" ]; then
        # Check if the General section exists
        if grep -q "^\[Containments\]\[$TRAY_ID\]\[General\]$" "$APPLETS_FILE"; then
          # Add or update shownItems in the General section
          if grep -q "^shownItems=" "$APPLETS_FILE"; then
            sed -i "/^\[Containments\]\[$TRAY_ID\]\[General\]$/,/^\[/ {
              /^shownItems=/d
              /^hiddenItems=/d
            }" "$APPLETS_FILE"
          fi
          # Append the settings after the [General] header
          sed -i "/^\[Containments\]\[$TRAY_ID\]\[General\]$/a shownItems=$ALL_ITEMS\nhiddenItems=" "$APPLETS_FILE"
        fi
      fi

      # Also update any existing shownItems= lines in systemtray applet config
      sed -i "s/^shownItems=.*/shownItems=$ALL_ITEMS/" "$APPLETS_FILE"
      sed -i "s/^hiddenItems=.*/hiddenItems=/" "$APPLETS_FILE"
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
    };

    # Window rules for autostart positioning
    window-rules = [
      {
        description = "Konsole - Left Half";
        match = {
          window-class = {
            value = "konsole";
            type = "substring";
          };
        };
        apply = {
          position = {
            value = "0,0";
            apply = "initially";
          };
          size = {
            value = "960,1080";
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
            value = "960,0";
            apply = "initially";
          };
          size = {
            value = "960,1080";
            apply = "initially";
          };
        };
      }
    ];

    # ─────────────────────────────────────────────────────────────────
    # Startup - Autostart apps
    # ─────────────────────────────────────────────────────────────────
    startup = {
      startupScript = {
        "launch-konsole-dolphin" = {
          text = ''
            # Wait for Plasma to fully start
            sleep 2
            # Open Konsole on left half
            konsole &
            sleep 0.5
            # Open Dolphin on right half
            dolphin ~ &
          '';
        };
      };
    };

    # ─────────────────────────────────────────────────────────────────
    # Panel Configuration - Bottom Panel
    # ─────────────────────────────────────────────────────────────────
    # Using panels config - this will be managed by Nix
    # Note: This recreates panels on rebuild, but ensures declarative state
    panels = [
      {
        location = "bottom";
        height = 44;
        hiding = "none";
        floating = false;
        widgets = [
          # Application Menu (Kickoff) - LEFT
          {
            kickoff = {
              icon = "nix-snowflake-white";
            };
          }
          # Virtual Desktop Pager
          {
            pager = {
              general = {
                displayedText = "desktopNumber";
              };
            };
          }
          # Separator
          "org.kde.plasma.marginsseparator"
          # Icon Tasks (Taskbar)
          {
            iconTasks = {
              launchers = [
                "applications:org.kde.dolphin.desktop"
                "applications:org.kde.konsole.desktop"
                "applications:obsidian.desktop"
                "applications:brave-browser.desktop"
                "applications:waydroid.desktop"
                "applications:systemsettings.desktop"
              ];
            };
          }
          # Spacer
          "org.kde.plasma.panelspacer"
          # System Monitors (CPU, RAM, Disk)
          {
            systemMonitor = {
              displayStyle = "org.kde.ksysguard.textonly";
              sensors = [
                {
                  name = "cpu/all/usage";
                  color = "97,174,238";
                  label = "CPU";
                }
              ];
            };
          }
          {
            systemMonitor = {
              displayStyle = "org.kde.ksysguard.textonly";
              sensors = [
                {
                  name = "memory/physical/usedPercent";
                  color = "46,194,126";
                  label = "RAM";
                }
              ];
            };
          }
          {
            systemMonitor = {
              displayStyle = "org.kde.ksysguard.textonly";
              sensors = [
                {
                  name = "disk/all/usedPercent";
                  color = "246,116,0";
                  label = "Disk";
                }
              ];
            };
          }
          # System Tray - ALL VISIBLE
          {
            systemTray = {
              items = {
                shown = [
                  "org.kde.plasma.battery"
                  "org.kde.plasma.bluetooth"
                  "org.kde.plasma.brightness"
                  "org.kde.plasma.networkmanagement"
                  "org.kde.plasma.volume"
                  "org.kde.plasma.clipboard"
                  "org.kde.plasma.devicenotifier"
                  "org.kde.plasma.notifications"
                  "org.kde.kdeconnect"
                  "org.kde.kscreen"
                  "org.kde.plasma.keyboardlayout"
                  "org.kde.plasma.keyboardindicator"
                  "org.kde.plasma.cameraindicator"
                  "org.kde.plasma.manage-inputmethod"
                  "org.kde.plasma.mediacontroller"
                ];
                hidden = [];
              };
            };
          }
          # Digital Clock
          {
            digitalClock = {
              date = {
                enable = true;
                format = { custom = "dd-MM-yyyy"; };
                position = "belowTime";
              };
              time = {
                format = "24h";
                showSeconds = "onlyInTooltip";
              };
              calendar = {
                firstDayOfWeek = "monday";
              };
            };
          }
          # User Switcher - RIGHT
          "org.kde.plasma.userswitcher"
        ];
      }
    ];

    # ─────────────────────────────────────────────────────────────────
    # KDE Config Files (via configFile - non-destructive merge)
    # ─────────────────────────────────────────────────────────────────
    configFile = {
      # Digital Clock - 24h format and dd-MM-yyyy date
      "plasma-org.kde.plasma.desktop-appletsrc"."Containments.244.Applets.265.Configuration.Appearance" = {
        use24hFormat = 2;
        dateFormat = "custom";
        customDateFormat = "dd-MM-yyyy";
      };

      # System Tray - ALL items always visible (ID 308 after panel recreation)
      "plasma-org.kde.plasma.desktop-appletsrc"."Containments.308.General" = {
        extraItems = "org.kde.plasma.battery,org.kde.plasma.bluetooth,org.kde.plasma.brightness,org.kde.plasma.networkmanagement,org.kde.plasma.volume,org.kde.plasma.clipboard,org.kde.plasma.devicenotifier,org.kde.plasma.notifications,org.kde.kdeconnect,org.kde.kscreen,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.cameraindicator,org.kde.plasma.manage-inputmethod,org.kde.plasma.mediacontroller";
        knownItems = "org.kde.plasma.battery,org.kde.plasma.bluetooth,org.kde.plasma.brightness,org.kde.plasma.networkmanagement,org.kde.plasma.volume,org.kde.plasma.clipboard,org.kde.plasma.devicenotifier,org.kde.plasma.notifications,org.kde.kdeconnect,org.kde.kscreen,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.cameraindicator,org.kde.plasma.manage-inputmethod,org.kde.plasma.mediacontroller";
        shownItems = "org.kde.plasma.battery,org.kde.plasma.bluetooth,org.kde.plasma.brightness,org.kde.plasma.networkmanagement,org.kde.plasma.volume,org.kde.plasma.clipboard,org.kde.plasma.devicenotifier,org.kde.plasma.notifications,org.kde.kdeconnect,org.kde.kscreen,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.cameraindicator,org.kde.plasma.manage-inputmethod,org.kde.plasma.mediacontroller";
        hiddenItems = "";
      };

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
}
