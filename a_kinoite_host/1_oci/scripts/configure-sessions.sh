#!/bin/sh
# Configure available sessions based on detected profile
# Runs at boot via systemd service
# POSIX-compliant

SESSIONS_WAYLAND="/usr/share/wayland-sessions"
SESSIONS_X11="/usr/share/xsessions"

# Detect profile: if inner LUKS is mounted, we're AUTH
# Check for @vault-auth mount (only available in AUTH profile)
if findmnt /home/diego/vault >/dev/null 2>&1; then
    PROFILE="auth"
    AUTO_USER="diego"
else
    PROFILE="anon"
    AUTO_USER="anon"
fi

echo "Detected profile: $PROFILE"

# Enable/disable sessions based on profile
if [ "$PROFILE" = "anon" ]; then
    # ANON: Enable Tor Kiosk, disable Chrome Kiosk
    chmod 644 "$SESSIONS_WAYLAND/tor-kiosk.desktop" 2>/dev/null || true
    chmod 000 "$SESSIONS_WAYLAND/chrome-kiosk.desktop" 2>/dev/null || true
else
    # AUTH: Enable Chrome Kiosk, disable Tor Kiosk
    chmod 000 "$SESSIONS_WAYLAND/tor-kiosk.desktop" 2>/dev/null || true
    chmod 644 "$SESSIONS_WAYLAND/chrome-kiosk.desktop" 2>/dev/null || true
fi

# SECURITY: NO auto-login - require password at SDDM
# LUKS password is the primary auth layer, but we still require SDDM login
# This prevents unauthorized access if system is left unlocked
mkdir -p /etc/sddm.conf.d

# Remove any existing autologin config
rm -f /etc/sddm.conf.d/autologin.conf

# Set default user (not auto-login, just pre-selected)
cat > /etc/sddm.conf.d/default-user.conf << EOF
[Users]
RememberLastUser=true
RememberLastSession=true

[Autologin]
# DISABLED - Security requires password entry
# Auto-login is only safe in production with LUKS encryption
EOF

echo "Configured for $PROFILE profile (NO auto-login, password required)"
