# ═══════════════════════════════════════════════════════════════════════════
# CUSTOM SDDM SESSIONS MODULE
# ═══════════════════════════════════════════════════════════════════════════
# Defines custom wayland sessions, hides unwanted sessions, and controls order.
# Default: Plasma (Wayland)
#
# Order: Plasma, GNOME, Android, Openbox, Chrome Kiosk, Tor Kiosk, GNOME Kiosk

{ config, pkgs, lib, ... }:

let
  # Helper to create a wayland session package with providedSessions
  mkWaylandSession = { name, desktopName, comment, exec }:
    pkgs.runCommand "${name}-session" {
      passthru.providedSessions = [ name ];
    } ''
      mkdir -p $out/share/wayland-sessions
      cat > $out/share/wayland-sessions/${name}.desktop << EOF
      [Desktop Entry]
      Name=${desktopName}
      Comment=${comment}
      Exec=${exec}
      Type=Application
      DesktopNames=${desktopName}
      EOF
    '';

  # Helper to create an X11 session package with providedSessions
  mkX11Session = { name, desktopName, comment, exec }:
    pkgs.runCommand "${name}-session" {
      passthru.providedSessions = [ name ];
    } ''
      mkdir -p $out/share/xsessions
      cat > $out/share/xsessions/${name}.desktop << EOF
      [Desktop Entry]
      Name=${desktopName}
      Comment=${comment}
      Exec=${exec}
      Type=Application
      DesktopNames=${desktopName}
      EOF
    '';

  # Helper to hide an X11 session (no providedSessions needed for hidden)
  mkHiddenX11Session = name:
    pkgs.runCommand "hide-${name}-x11-session" {
      passthru.providedSessions = [ name ];
    } ''
      mkdir -p $out/share/xsessions
      cat > $out/share/xsessions/${name}.desktop << EOF
      [Desktop Entry]
      Hidden=true
      NoDisplay=true
      EOF
    '';

  # Helper to hide a Wayland session
  mkHiddenWaylandSession = name:
    pkgs.runCommand "hide-${name}-wayland-session" {
      passthru.providedSessions = [ name ];
    } ''
      mkdir -p $out/share/wayland-sessions
      cat > $out/share/wayland-sessions/${name}.desktop << EOF
      [Desktop Entry]
      Hidden=true
      NoDisplay=true
      EOF
    '';

  # ─────────────────────────────────────────────────────────────────────────
  # ORDERED SESSIONS (using numeric prefix for SDDM alphabetical sort)
  # ─────────────────────────────────────────────────────────────────────────
  # 1. Plasma (Wayland) - override default
  plasmaSession = mkWaylandSession {
    name = "plasma";
    desktopName = "1. Plasma";
    comment = "KDE Plasma Desktop (Wayland)";
    exec = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland";
  };

  # 2. GNOME - override default
  gnomeSession = mkWaylandSession {
    name = "gnome";
    desktopName = "2. GNOME";
    comment = "GNOME Desktop Environment";
    exec = "${pkgs.gnome-session}/bin/gnome-session";
  };

  # 3. Android (Waydroid)
  androidSession = mkWaylandSession {
    name = "android";
    desktopName = "3. Android";
    comment = "Full Android UI via Waydroid";
    exec = "${pkgs.cage}/bin/cage -- ${pkgs.waydroid}/bin/waydroid show-full-ui";
  };

  # 4. Openbox (X11)
  openboxSession = mkX11Session {
    name = "none+openbox";
    desktopName = "4. Openbox";
    comment = "Openbox window manager";
    exec = "openbox-session";
  };

  # 5. Chrome Kiosk
  chromeKioskSession = mkWaylandSession {
    name = "chrome-kiosk";
    desktopName = "5. Chrome Kiosk";
    comment = "Chromium kiosk mode";
    exec = "${pkgs.cage}/bin/cage -- ${pkgs.chromium}/bin/chromium --kiosk --start-fullscreen";
  };

  # 6. Tor Kiosk
  torKioskSession = mkWaylandSession {
    name = "tor-kiosk";
    desktopName = "6. Tor Kiosk";
    comment = "Anonymous browsing via Tor Browser";
    exec = "${pkgs.cage}/bin/cage -- ${pkgs.tor-browser}/bin/tor-browser";
  };

  # 7. GNOME Kiosk
  gnomeKioskSession = mkWaylandSession {
    name = "gnome-kiosk";
    desktopName = "7. GNOME Kiosk";
    comment = "Locked down GNOME session";
    exec = "${pkgs.gnome-session}/bin/gnome-session --session=gnome";
  };

  # ─────────────────────────────────────────────────────────────────────────
  # HIDDEN SESSIONS
  # ─────────────────────────────────────────────────────────────────────────
  # Hide all X11 sessions (except our Openbox override)
  hiddenPlasmaX11 = mkHiddenX11Session "plasmax11";
  hiddenGnomeX11 = mkHiddenX11Session "gnome-x11";
  hiddenGnomeXorg = mkHiddenX11Session "gnome-xorg";

  # Hide duplicate/original Wayland sessions
  hiddenGnomeWayland = mkHiddenWaylandSession "gnome-wayland";

in {
  # Register all sessions with display manager
  services.displayManager.sessionPackages = [
    # Ordered sessions
    plasmaSession
    gnomeSession
    androidSession
    openboxSession
    chromeKioskSession
    torKioskSession
    gnomeKioskSession
    # Hidden X11 sessions
    hiddenPlasmaX11
    hiddenGnomeX11
    hiddenGnomeXorg
    # Hidden duplicate Wayland
    hiddenGnomeWayland
  ];

  # Default session: Plasma Wayland
  services.displayManager.defaultSession = lib.mkDefault "plasma";
}
