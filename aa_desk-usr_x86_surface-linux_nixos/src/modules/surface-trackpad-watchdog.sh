# surface-trackpad-watchdog — periodic HID reset to clear the Surface Type
# Cover's stuck BTN_0 (phantom mouse button) state on kernels without the
# hid-surface fix
#
# Extracted from hardware_surface.nix
# (systemd.services.surface-trackpad-watchdog.script). Runtime-data-driven:
# the reset interval and the touchpad name to match are read from
# /etc/cloud-data/surface-trackpad-watchdog.json via jq at RUNTIME. Real
# binary paths (modprobe, pgrep, grep) arrive via writeShellApplication
# runtimeInputs.
#
# Whether this unit even exists is gated build-time in hardware_surface.nix
# via lib.mkIf (lib.versionOlder ... "6.17.13") — that stays Nix-side per the
# task's rule 3 (systemd needs it at build/eval time to decide whether to
# generate the unit at all).
#
# Fail-loud: NO — this is a best-effort background watchdog for a cosmetic
# input bug, After=graphical.target with Restart=always. A hard exit on a
# transient `modprobe` failure would just bounce the unit (RestartSec=5) with
# no benefit over the original `|| true` tolerance, and there's no state file
# or exit-code contract to preserve. Every modprobe -r keeps its `|| true`
# exactly as before.
set -u

CONFIG_JSON="${TRACKPAD_WATCHDOG_CONFIG_JSON:-/etc/cloud-data/surface-trackpad-watchdog.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t surface-trackpad-watchdog -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

INTERVAL_SEC="$(jq -r '.interval_sec' "$CONFIG_JSON")"
TOUCHPAD_NAME="$(jq -r '.touchpad_name' "$CONFIG_JSON")"

# Only run on Plasma
while ! pgrep -f kwin_wayland >/dev/null 2>&1; do sleep 5; done
echo "[trackpad-watchdog] Plasma detected"

# Proactive reset every interval — lightweight, no detection needed.
# The HID reset takes <2s and causes no visible interruption. This prevents
# BTN_LEFT from staying dead for more than one interval.
while true; do
  sleep "$INTERVAL_SEC"
  # Only reset if touchpad exists
  if grep -rq "$TOUCHPAD_NAME" /sys/class/input/event*/device/name 2>/dev/null; then
    echo "[trackpad-watchdog] Periodic HID reset"
    modprobe -r surface_hid_core surface_hid 2>/dev/null || true
    modprobe surface_hid_core surface_hid
    modprobe -r hid_multitouch 2>/dev/null || true
    modprobe hid_multitouch
    modprobe -r usbhid 2>/dev/null || true
    modprobe usbhid
    modprobe -r surface_aggregator_registry surface_aggregator_hub surface_hid surface_hid_core 2>/dev/null || true
    sleep 1
    modprobe surface_aggregator_registry
    modprobe surface_hid
  fi
done
