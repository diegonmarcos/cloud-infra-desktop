#!/usr/bin/env bash
# Mode dispatcher for the Kali container.
# Reads /install.json (mounted read-only by compose) for mode parameters.
# Args:
#   cli   — exec login shell (default; intended for `docker exec` / `docker attach`)
#   gui   — start XFCE4 + TigerVNC + noVNC, hold container alive
#   shell — alias for cli
#   *     — exec the args verbatim
set -euo pipefail

CFG="${KALI_INSTALL_JSON:-/install.json}"

jq_get() {
    local path="$1" default="${2:-}"
    if [[ -r "$CFG" ]] && command -v jq >/dev/null 2>&1; then
        jq -r "$path // empty" "$CFG" 2>/dev/null || true
    else
        echo "$default"
    fi
}

start_gui() {
    local display geom depth vnc_port novnc_port pw_file pw
    display="$(jq_get '.modes.gui.display' ':1')"
    geom="$(jq_get   '.modes.gui.geometry' '1920x1080')"
    depth="$(jq_get  '.modes.gui.depth' '24')"
    vnc_port="$(jq_get   '.modes.gui.vnc_port'   '5901')"
    novnc_port="$(jq_get '.modes.gui.novnc_port' '6901')"
    pw_file="$(jq_get '.env.VNC_PASSWORD_FILE' "$HOME/.vnc/passwd")"
    pw="${KALI_VNC_PASSWORD:-$(jq_get '.secrets.vnc_password_default' 'kali')}"

    mkdir -p "$(dirname "$pw_file")" "$HOME/.vnc"
    printf '%s\n%s\nn\n' "$pw" "$pw" | vncpasswd -f > "$pw_file" 2>/dev/null \
        || echo "$pw" | vncpasswd -f > "$pw_file"
    chmod 600 "$pw_file"

    cat > "$HOME/.vnc/xstartup" <<'XSTARTUP'
#!/usr/bin/env bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
export XDG_CURRENT_DESKTOP=XFCE
exec dbus-launch --exit-with-session startxfce4
XSTARTUP
    chmod +x "$HOME/.vnc/xstartup"

    vncserver -kill "$display" >/dev/null 2>&1 || true
    rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true

    vncserver "$display" \
        -geometry "$geom" \
        -depth "$depth" \
        -localhost no \
        -rfbport "$vnc_port" \
        -PasswordFile "$pw_file" \
        -SecurityTypes VncAuth >/dev/null

    if command -v websockify >/dev/null 2>&1 && [[ -d /usr/share/novnc ]]; then
        websockify --web=/usr/share/novnc \
                   "$novnc_port" "localhost:${vnc_port}" &
    fi

    echo "[kali-gui] VNC   :${vnc_port}    (password: see install.json or KALI_VNC_PASSWORD)"
    echo "[kali-gui] noVNC :${novnc_port}  → http://localhost:${novnc_port}/"
    tail -F "$HOME/.vnc/"*.log
}

mode="${1:-cli}"
case "$mode" in
    cli|shell)
        shell="$(jq_get '.user.shell' '/bin/bash')"
        exec "$shell" -l
        ;;
    gui|desktop)
        start_gui
        ;;
    *)
        exec "$@"
        ;;
esac
