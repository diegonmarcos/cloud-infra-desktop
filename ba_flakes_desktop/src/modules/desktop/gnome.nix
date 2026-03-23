# GNOME configuration via dconf
{ config, pkgs, lib, ... }:

{
  # ─────────────────────────────────────────────────────────────────
  # GNOME/GTK Theming
  # ─────────────────────────────────────────────────────────────────
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
    cursorTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
  };

  # Qt apps in GNOME (match dark theme)
  qt = {
    enable = true;
    platformTheme.name = "adwaita";
    style.name = "adwaita-dark";
  };

  # ─────────────────────────────────────────────────────────────────
  # dconf settings (GNOME configuration database)
  # ─────────────────────────────────────────────────────────────────
  dconf = {
    enable = true;
    settings = {
      # ─── Appearance ───────────────────────────────────────────────
      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        gtk-theme = "Adwaita-dark";
        icon-theme = "Adwaita";
        cursor-theme = "Adwaita";
        cursor-size = 24;
        font-antialiasing = "rgba";
        font-hinting = "slight";
        # Scaling
        text-scaling-factor = 1.25;
      };

      # ─── Display Scaling & Workspaces ─────────────────────────────
      "org/gnome/mutter" = {
        experimental-features = [ "scale-monitor-framebuffer" ];
        dynamic-workspaces = false;
      };

      # ─── Touchpad (tap-to-click, tap-and-drag) ────────────────────
      "org/gnome/desktop/peripherals/touchpad" = {
        tap-to-click = true;
        tap-and-drag = true;
        natural-scroll = true;
        two-finger-scrolling-enabled = true;
        speed = 0.3;
      };

      # ─── Mouse ────────────────────────────────────────────────────
      "org/gnome/desktop/peripherals/mouse" = {
        natural-scroll = false;
        speed = 0.0;
      };

      # ─── Keyboard shortcuts ───────────────────────────────────────
      "org/gnome/desktop/wm/keybindings" = {
        close = [ "<Alt>F4" ];
        maximize = [ "<Super>Up" ];
        minimize = [ "<Super>Down" ];
        switch-to-workspace-1 = [ "<Super>1" ];
        switch-to-workspace-2 = [ "<Super>2" ];
        switch-to-workspace-3 = [ "<Super>3" ];
        switch-to-workspace-4 = [ "<Super>4" ];
      };

      "org/gnome/settings-daemon/plugins/media-keys" = {
        home = [ "<Super>e" ];
      };

      # Custom terminal shortcut
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        name = "Terminal";
        command = "gnome-terminal";
        binding = "<Super>Return";
      };

      "org/gnome/settings-daemon/plugins/media-keys" = {
        custom-keybindings = [
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        ];
      };

      # ─── Workspaces ───────────────────────────────────────────────
      "org/gnome/desktop/wm/preferences" = {
        num-workspaces = 4;
      };

      # ─── Power ────────────────────────────────────────────────────
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-battery-timeout = 900;
      };

      # ─── Night Light ──────────────────────────────────────────────
      "org/gnome/settings-daemon/plugins/color" = {
        night-light-enabled = true;
        night-light-schedule-automatic = true;
      };

      # ─── Extensions ────────────────────────────────────────────────
      "org/gnome/shell" = {
        enabled-extensions = [
          "appindicatorsupport@rgcjonas.gmail.com"
          "dash-to-dock@micxgx.gmail.com"
          "clipboard-indicator@tudmotu.com"
          "gsconnect@andyholmes.github.io"
        ];
      };

      # ─── Privacy ──────────────────────────────────────────────────
      "org/gnome/desktop/privacy" = {
        remember-recent-files = true;
        remove-old-trash-files = true;
        remove-old-temp-files = true;
        old-files-age = 30;
      };
    };
  };

  # GNOME extensions (optional)
  home.packages = with pkgs; [
    gnomeExtensions.appindicator
    gnomeExtensions.dash-to-dock
    gnomeExtensions.clipboard-indicator
    gnomeExtensions.gsconnect
  ];
}
