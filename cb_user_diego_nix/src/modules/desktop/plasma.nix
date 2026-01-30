# KDE Plasma configuration
# Requires plasma-manager input in flake.nix
{ config, pkgs, lib, ... }:

{
  programs.plasma = {
    enable = true;

    # ─────────────────────────────────────────────────────────────────
    # Appearance
    # ─────────────────────────────────────────────────────────────────
    workspace = {
      theme = "breeze-dark";
      colorScheme = "BreezeDark";
      cursor.theme = "breeze_cursors";
      iconTheme = "breeze-dark";
      lookAndFeel = "org.kde.breezedark.desktop";
    };

    # ─────────────────────────────────────────────────────────────────
    # Keyboard shortcuts
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
    # Window behavior
    # ─────────────────────────────────────────────────────────────────
    kwin = {
      effects.shakeCursor.enable = true;
      virtualDesktops = {
        number = 4;
        rows = 1;
        names = [ "Desktop 1" "Desktop 2" "Desktop 3" "Desktop 4" ];
      };
    };

    # ─────────────────────────────────────────────────────────────────
    # Panel configuration (icons-only taskbar)
    # ─────────────────────────────────────────────────────────────────
    panels = [
      {
        location = "bottom";
        height = 44;
        floating = true;
        widgets = [
          {
            name = "org.kde.plasma.pager";
            config.General = {
              displayedText = "Number";
              showWindowIcons = true;
            };
          }
          "org.kde.plasma.marginsseparator"
          {
            name = "org.kde.plasma.icontasks";
            config.General = {
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
          "org.kde.plasma.panelspacer"
          { name = "org.kde.plasma.systemtray"; }
          {
            name = "org.kde.plasma.digitalclock";
            config.Appearance = {
              showDate = true;
              dateFormat = "shortDate";
            };
          }
        ];
      }
    ];
  };

  # ─────────────────────────────────────────────────────────────────
  # KDE config files (for settings not in plasma-manager)
  # ─────────────────────────────────────────────────────────────────
  home.file.".config/kcminputrc".text = ''
    [Libinput][1267][12693][ELAN0732:00 04F3:3195 Touchpad]
    NaturalScroll=true
    PointerAcceleration=0.3
    TapToClick=true
    TapDragLock=true

    [Touchpad]
    TapToClick=true
    TapDragLock=true
    NaturalScroll=true
  '';

  home.file.".config/kdeglobals".text = ''
    [KDE]
    LookAndFeelPackage=org.kde.breezedark.desktop

    [KScreen]
    ScaleFactor=1.25
    ScreenScaleFactors=eDP-1=1.25;
  '';

  # ─────────────────────────────────────────────────────────────────
  # Qt theming - DISABLED: causes Qt5/Qt6 breeze collision
  # Plasma 6 handles Qt theming automatically
  # ─────────────────────────────────────────────────────────────────
  # qt = {
  #   enable = true;
  #   platformTheme.name = "kde";
  #   style.name = "breeze";
  # };

  # ─────────────────────────────────────────────────────────────────
  # GTK apps in Plasma (dark theme)
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
      size = 24;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
  };
}
