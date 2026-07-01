# ═══════════════════════════════════════════════════════════════════════════
# CUSTOM SDDM SESSIONS MODULE
# ═══════════════════════════════════════════════════════════════════════════
# Controls session list order and hides unwanted sessions.
# Default: Plasma (Wayland)
#
# Visible (in order): Plasma, GNOME, Chrome Kiosk, Tor Kiosk, Openbox

{ config, pkgs, lib, ... }:

let
  # Paths for Exec= lines
  plasmaExec = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland";

  # Plasma "Fresh" session — overrides ksmserverrc loginMode=emptySession via
  # an XDG_CONFIG_HOME overlay so plasma starts clean WITHOUT mutating the
  # user's real config (which has loginMode=restoreSavedSession baked in by
  # ba_flakes_desktop/src/modules/desktop/session-restore.nix). On logout
  # the overlay dir is discarded, so any session state plasma writes during
  # this fresh login does NOT pollute the saved-session snapshot.
  plasmaFreshExec = pkgs.writeShellScript "plasma-fresh-wayland" ''
    set -e
    REAL_CFG="''${XDG_CONFIG_HOME:-$HOME/.config}"
    OVERLAY=$(${pkgs.coreutils}/bin/mktemp -d -t plasma-fresh-XXXXXX)
    # Symlink everything from real config into overlay (cheap, no copy).
    ${pkgs.coreutils}/bin/ln -s "$REAL_CFG"/* "$OVERLAY/" 2>/dev/null || true
    # Override JUST ksmserverrc to force empty session for this login.
    ${pkgs.coreutils}/bin/rm -f "$OVERLAY/ksmserverrc"
    ${pkgs.coreutils}/bin/cp "$REAL_CFG/ksmserverrc" "$OVERLAY/ksmserverrc" 2>/dev/null || true
    ${pkgs.gnused}/bin/sed -i 's/^loginMode=.*/loginMode=emptySession/' "$OVERLAY/ksmserverrc" 2>/dev/null || \
      ${pkgs.coreutils}/bin/printf '[General]\nloginMode=emptySession\n' > "$OVERLAY/ksmserverrc"
    # Clean overlay on session exit.
    trap '${pkgs.coreutils}/bin/rm -rf "$OVERLAY"' EXIT
    XDG_CONFIG_HOME="$OVERLAY" exec ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland
  '';
  gnomeExec = "${pkgs.gnome-session}/bin/gnome-session";
  chromeExec = "${pkgs.cage}/bin/cage -- ${pkgs.chromium}/bin/chromium --kiosk --start-fullscreen";
  torExec = "${pkgs.cage}/bin/cage -- ${pkgs.tor-browser}/bin/tor-browser";

  # ─────────────────────────────────────────────────────────────────────────
  # SESSION PACKAGE
  # ─────────────────────────────────────────────────────────────────────────
  customSessions = pkgs.runCommand "custom-sddm-sessions" {
    passthru.providedSessions = [
      "01-plasma"
      "01b-plasma-fresh"
      "02-gnome"
      "04-chrome-kiosk"
      "05-tor-kiosk"
      "06-openbox"
      "07-gnome-kiosk"
    ];
  } ''
    mkdir -p $out/share/wayland-sessions
    mkdir -p $out/share/xsessions

    # ─── 1. Plasma 6 (Restore) — DEFAULT ──────────────────────────────────
    # ksmserverrc loginMode is set declaratively by
    # ba_flakes_desktop/src/modules/desktop/session-restore.nix.
    # Currently restorePreviousSession (Stage A) → restoreSavedSession
    # once a snapshot is captured (Stage B). Either way: this entry uses
    # the user's real config, which restores the saved/previous session.
    cat > $out/share/wayland-sessions/01-plasma.desktop << EOF
[Desktop Entry]
Type=Application
Name=Plasma 6 (Restore)
Comment=KDE Plasma — restores saved session (default)
Exec=${plasmaExec}
DesktopNames=KDE
EOF

    # ─── 1b. Plasma 6 (Fresh) — toggle to skip session restore ────────────
    # Wraps startplasma-wayland with an XDG_CONFIG_HOME overlay that
    # forces ksmserverrc loginMode=emptySession. Real config untouched.
    cat > $out/share/wayland-sessions/01b-plasma-fresh.desktop << EOF
[Desktop Entry]
Type=Application
Name=Plasma 6 (Fresh)
Comment=KDE Plasma — empty session (no restore, real config untouched)
Exec=${plasmaFreshExec}
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

    cat > $out/share/xsessions/none+openbox.desktop << EOF
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
  # Default to Plasma (our custom 01-plasma session)
  # mkForce needed to override plasma6.nix default
  services.displayManager.defaultSession = lib.mkForce "01-plasma";
}
