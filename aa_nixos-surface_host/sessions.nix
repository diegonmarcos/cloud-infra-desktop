# ═══════════════════════════════════════════════════════════════════════════
# CUSTOM SDDM SESSIONS MODULE
# ═══════════════════════════════════════════════════════════════════════════
# Controls session list order and hides unwanted sessions.
# Default: Plasma (Wayland)
#
# Visible (in order): Plasma, GNOME, Android, Chrome Kiosk, Tor Kiosk, Openbox

{ config, pkgs, lib, ... }:

let
  # Script for Android session (enables waydroid service)
  androidSessionScript = pkgs.writeShellScript "android-session" ''
    sudo ${pkgs.coreutils}/bin/touch /run/waydroid-enabled
    trap 'sudo ${pkgs.coreutils}/bin/rm -f /run/waydroid-enabled' EXIT
    ${pkgs.cage}/bin/cage -- ${pkgs.waydroid}/bin/waydroid show-full-ui
  '';

  # Paths for Exec= lines
  plasmaExec = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland";
  gnomeExec = "${pkgs.gnome-session}/bin/gnome-session";
  chromeExec = "${pkgs.cage}/bin/cage -- ${pkgs.chromium}/bin/chromium --kiosk --start-fullscreen";
  torExec = "${pkgs.cage}/bin/cage -- ${pkgs.tor-browser}/bin/tor-browser";

  # ─────────────────────────────────────────────────────────────────────────
  # SESSION PACKAGE
  # ─────────────────────────────────────────────────────────────────────────
  customSessions = pkgs.runCommand "custom-sddm-sessions" {
    passthru.providedSessions = [
      "01-plasma"
      "02-gnome"
      "03-android"
      "04-chrome-kiosk"
      "05-tor-kiosk"
      "06-openbox"
      "07-gnome-kiosk"
    ];
  } ''
    mkdir -p $out/share/wayland-sessions
    mkdir -p $out/share/xsessions

    # ─── 1. Plasma (Wayland) ───────────────────────────────────────────────
    cat > $out/share/wayland-sessions/01-plasma.desktop << EOF
[Desktop Entry]
Type=Application
Name=Plasma
Comment=KDE Plasma Desktop (Wayland)
Exec=${plasmaExec}
DesktopNames=KDE
EOF

    # ─── 2. GNOME (Wayland) ────────────────────────────────────────────────
    cat > $out/share/wayland-sessions/02-gnome.desktop << EOF
[Desktop Entry]
Type=Application
Name=GNOME
Comment=GNOME Desktop (Wayland)
Exec=${gnomeExec}
DesktopNames=GNOME
EOF

    # ─── 3. Android (Waydroid in Cage) ─────────────────────────────────────
    cat > $out/share/wayland-sessions/03-android.desktop << EOF
[Desktop Entry]
Type=Application
Name=Android
Comment=Android via Waydroid
Exec=${androidSessionScript}
DesktopNames=Android
EOF

    # ─── 4. Chrome Kiosk ───────────────────────────────────────────────────
    cat > $out/share/wayland-sessions/04-chrome-kiosk.desktop << EOF
[Desktop Entry]
Type=Application
Name=Chrome Kiosk
Comment=Chromium in kiosk mode
Exec=${chromeExec}
DesktopNames=Chromium
EOF

    # ─── 5. Tor Kiosk ──────────────────────────────────────────────────────
    cat > $out/share/wayland-sessions/05-tor-kiosk.desktop << EOF
[Desktop Entry]
Type=Application
Name=Tor Browser
Comment=Anonymous browsing via Tor
Exec=${torExec}
DesktopNames=Tor
EOF

    # ─── 6. Openbox (X11) ──────────────────────────────────────────────────
    cat > $out/share/xsessions/06-openbox.desktop << EOF
[Desktop Entry]
Type=Application
Name=Openbox
Comment=Lightweight X11 window manager
Exec=openbox-session
DesktopNames=Openbox
EOF

    # ─── 7. GNOME Kiosk ────────────────────────────────────────────────────
    cat > $out/share/wayland-sessions/07-gnome-kiosk.desktop << EOF
[Desktop Entry]
Type=Application
Name=GNOME Kiosk
Comment=Locked-down GNOME session
Exec=${gnomeExec} --session=gnome
DesktopNames=GNOME
EOF

    # ═══════════════════════════════════════════════════════════════════════
    # HIDE DUPLICATE/UNWANTED SESSIONS
    # ═══════════════════════════════════════════════════════════════════════
    # Must match EXACT filename of original to override

    # Hide original Plasma Wayland (we have 01-plasma)
    cat > $out/share/wayland-sessions/plasma.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    # Hide Plasma X11
    cat > $out/share/xsessions/plasmax11.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    # Hide original Openbox variants (we have 06-openbox)
    cat > $out/share/xsessions/openbox.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    cat > $out/share/xsessions/openbox-gnome.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    cat > $out/share/xsessions/openbox-kde.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    # Hide any GNOME X11/Xorg variants
    cat > $out/share/xsessions/gnome.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    cat > $out/share/xsessions/gnome-xorg.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    # Hide original GNOME Wayland (we have 02-gnome)
    cat > $out/share/wayland-sessions/gnome.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF

    cat > $out/share/wayland-sessions/gnome-wayland.desktop << EOF
[Desktop Entry]
Hidden=true
NoDisplay=true
EOF
  '';

in {
  # Register custom sessions
  services.displayManager.sessionPackages = [ customSessions ];

  # Default session
  services.displayManager.defaultSession = lib.mkDefault "01-plasma";
}
