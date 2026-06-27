# Session isolation: prevent GNOME services from activating in Plasma (and vice versa)
#
# Problem: NixOS installs both Plasma and GNOME as system-wide user services.
# GNOME's gsd-*, evolution-*, and Shell services D-Bus-activate even under Plasma,
# crash (SIGSEGV) because they expect Mutter, and cascade-crash KWin + Xwayland.
#
# Fix: systemd drop-in overrides gate each GNOME service on XDG_CURRENT_DESKTOP=GNOME.
# ConditionEnvironment= (systemd 256+) checks the user service manager environment,
# which inherits XDG_CURRENT_DESKTOP from the session (set by SDDM from DesktopNames=).
{ config, pkgs, lib, ... }:

let
  # All GNOME Settings Daemon services (gnome-settings-daemon-47.2)
  gsdServices = [
    "org.gnome.SettingsDaemon.A11ySettings"
    "org.gnome.SettingsDaemon.Color"
    "org.gnome.SettingsDaemon.Datetime"
    "org.gnome.SettingsDaemon.Housekeeping"
    "org.gnome.SettingsDaemon.Keyboard"
    "org.gnome.SettingsDaemon.MediaKeys"
    "org.gnome.SettingsDaemon.Power"
    "org.gnome.SettingsDaemon.PrintNotifications"
    "org.gnome.SettingsDaemon.Rfkill"
    "org.gnome.SettingsDaemon.ScreensaverProxy"
    "org.gnome.SettingsDaemon.Sharing"
    "org.gnome.SettingsDaemon.Smartcard"
    "org.gnome.SettingsDaemon.Sound"
    "org.gnome.SettingsDaemon.UsbProtection"
    "org.gnome.SettingsDaemon.Wacom"
    "org.gnome.SettingsDaemon.Wwan"
    "org.gnome.SettingsDaemon.XSettings"
  ];

  # GNOME Shell compositor and related services
  shellServices = [
    "org.gnome.Shell@wayland"
    "org.gnome.Shell@x11"
    "org.gnome.Shell-disable-extensions"
  ];

  # Evolution data services (pulled in by GNOME)
  evolutionServices = [
    "evolution-addressbook-factory"
    "evolution-calendar-factory"
    "evolution-source-registry"
    "evolution-user-prompter"
  ];

  allGnomeServices = gsdServices ++ shellServices ++ evolutionServices;

  # Package that provides systemd drop-in overrides for all GNOME services.
  # systemd.packages reads lib/systemd/user/<service>.d/*.conf as drop-ins.
  gnomeSessionGate = pkgs.runCommand "gnome-session-gate-dropins" {} ''
    ${lib.concatMapStringsSep "\n" (svc: ''
      mkdir -p $out/lib/systemd/user/${svc}.service.d
      cat > $out/lib/systemd/user/${svc}.service.d/50-session-gate.conf << 'EOF'
[Unit]
ConditionEnvironment=XDG_CURRENT_DESKTOP=GNOME
EOF
    '') allGnomeServices}

    # systembus-notify races D-Bus during nixos-switch activation → "Permission denied" at spawn.
    # Wait for graphical-session.target and allow more restarts to survive the window.
    mkdir -p $out/lib/systemd/user/systembus-notify.service.d
    cat > $out/lib/systemd/user/systembus-notify.service.d/50-wait-session.conf << 'EOF'
[Unit]
After=graphical-session.target

[Service]
RestartSec=3
StartLimitBurst=15
StartLimitIntervalSec=90
EOF
  '';

in {
  # ═══════════════════════════════════════════════════════════════════════════
  # 1. GNOME SERVICE GATING — Only start under GNOME sessions
  # ═══════════════════════════════════════════════════════════════════════════
  # Installs drop-in overrides via systemd.packages (the NixOS-native way to
  # extend package-provided units without replacing them).
  systemd.packages = [ gnomeSessionGate ];

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. XDG PORTALS — Session-aware defaults (not hardcoded)
  # ═══════════════════════════════════════════════════════════════════════════
  # Each DE gets its preferred portal. The "common" fallback uses gtk (works everywhere).
  # This replaces the previous `config.common.default = ["kde" "gtk"]` which made
  # KDE and GTK portals race regardless of active session.
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-kde
      xdg-desktop-portal-gtk
    ];
    config = {
      common.default = [ "kde" ];       # primary DE is KDE; GTK portal segfaults on non-GNOME (1.15.1)
      KDE.default = [ "kde" ];          # KDE portal handles everything — GTK portal not needed and segfaults
      GNOME.default = [ "gnome" "gtk" ];
    };
  };
}
