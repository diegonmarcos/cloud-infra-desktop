#!/bin/sh
# Session Switcher - shows session picker for quick session changes
# Allows switching sessions without going back to SDDM login screen
# Can be bound to a hotkey or added to menu
# POSIX-compliant

LAST_SESSION="$HOME/.config/last-session"
CURRENT_SESSION="${XDG_CURRENT_DESKTOP:-plasma}"

# Detect profile based on current user
if [ "$USER" = "anon" ]; then
    SESSIONS="KDE Plasma
Openbox
Android
Tor Kiosk"
else
    SESSIONS="KDE Plasma
Openbox
Android
Chrome Kiosk"
fi

# Show picker if no saved session or --choose flag
show_picker=0
if [ ! -f "$LAST_SESSION" ]; then
    show_picker=1
elif [ "$1" = "--choose" ]; then
    show_picker=1
fi

if [ "$show_picker" -eq 1 ]; then
    CHOICE=$(echo "$SESSIONS" | zenity --list --title="Choose Session" \
        --text="Select your desktop environment:" \
        --column="Session" \
        --width=300 --height=300)

    if [ -n "$CHOICE" ]; then
        echo "$CHOICE" > "$LAST_SESSION"

        # Map choice to session file
        case "$CHOICE" in
            "KDE Plasma") SESSION="plasma" ;;
            "Openbox") SESSION="openbox" ;;
            "Android") SESSION="android" ;;
            "Tor Kiosk") SESSION="tor-kiosk" ;;
            "Chrome Kiosk") SESSION="chrome-kiosk" ;;
        esac

        # If different from current, logout and switch
        if [ "$SESSION" != "$CURRENT_SESSION" ]; then
            mkdir -p ~/.config
            echo "Session=$SESSION.desktop" > ~/.config/sddm-session
            loginctl terminate-user "$USER"
        fi
    fi
fi
