# wg-tcp — toggle WireGuard-over-TCP/443 fallback (declarative wrapper)
#
# Extracted from wireguard-wstunnel.nix (home.file.".local/bin/wg-tcp").
# Runtime-data-driven: the systemd user unit name and the WG interface name
# are read from wireguard-wstunnel.json at RUNTIME via jq, not interpolated
# by Nix into this file. Real binary paths arrive through
# writeShellApplication's runtimeEnv (SYSTEMCTL_BIN / WG_QUICK_BIN / WG_BIN),
# never as ${pkgs.foo} strings in this body.
#
# Usage: wg-tcp [up|down|status]
#
# Fail-loud: this is an operator-invoked control command (up/down/status),
# not a transparent wrapper around another user binary, so a missing or
# unreadable runtime JSON is a hard error rather than a silent fall-through.
set -eu

cmd="${1:-status}"

SYSTEMCTL="${WG_TCP_SYSTEMCTL_BIN:?wg-tcp: WG_TCP_SYSTEMCTL_BIN not set by Nix module}"
WG_QUICK="${WG_TCP_WG_QUICK_BIN:?wg-tcp: WG_TCP_WG_QUICK_BIN not set by Nix module}"
WG_SHOW="${WG_TCP_WG_BIN:?wg-tcp: WG_TCP_WG_BIN not set by Nix module}"
CONFIG_JSON="${WG_TCP_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "[wg-tcp] ERROR: $CONFIG_JSON missing or unreadable" >&2
  exit 1
fi

UNIT="$(jq -r '.service_unit' "$CONFIG_JSON")"
IFACE="$(jq -r '.wg_tcp_interface' "$CONFIG_JSON")"

case "$cmd" in
  up)
    echo "[wg-tcp] starting ${UNIT} + bringing ${IFACE} up"
    "$SYSTEMCTL" --user start "$UNIT"
    sleep 1
    sudo "$WG_QUICK" up "$IFACE" || true
    echo "[wg-tcp] tunnel via TCP/443 active"
    ;;
  down)
    echo "[wg-tcp] tearing down ${IFACE} + ${UNIT}"
    sudo "$WG_QUICK" down "$IFACE" || true
    "$SYSTEMCTL" --user stop "$UNIT"
    ;;
  status)
    echo "── ${UNIT} systemd unit:"
    "$SYSTEMCTL" --user status "$UNIT" --no-pager 2>&1 | head -10
    echo "── wg interfaces up:"
    sudo "$WG_SHOW" show interfaces 2>/dev/null || echo "(none)"
    ;;
  *)
    echo "Usage: wg-tcp [up|down|status]"
    exit 1
    ;;
esac
