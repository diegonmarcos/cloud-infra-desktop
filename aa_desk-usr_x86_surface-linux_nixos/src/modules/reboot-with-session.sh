# reboot-with-session — the RAM-session counterpart for restarts: write the
# full hibernate image, then REBOOT instead of powering off.
#
# Extracted from configuration_session-checkpoint.nix's inline
# `pkgs.writeShellApplication { text = ''...''; }` body (no eval-time
# generation here — a single fixed script — moved to a sibling .sh per repo
# convention that no shell body lives inline in a .nix file).
#
# Kernel disk-mode 'reboot' via a RUNTIME sleep.conf.d drop-in that only
# exists for this invocation: /run is tmpfs, so a completed reboot wipes it,
# and the battery-watchdog's critical hibernate keeps its normal power-off
# semantics. At the boot menu: NixOS - Primary resumes the session; NixOS -
# Fresh Desktop starts clean. For booting a NEW kernel, use plain `reboot` —
# resuming the image returns to the old kernel by design.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "reboot-with-session: must run as root (sudo)" >&2
  exit 1
fi

DROPIN_DIR=/run/systemd/sleep.conf.d
DROPIN="$DROPIN_DIR/zz-reboot-with-session.conf"
mkdir -p "$DROPIN_DIR"
printf '[Sleep]\nHibernateMode=reboot\n' > "$DROPIN"
# If hibernate is refused (no swap, masked, gate tripped), remove the
# drop-in so a later battery-critical hibernate still powers OFF.
# On success the machine reboots and tmpfs /run discards it anyway;
# if the session is RESUMED later, /run came back from the image —
# the trap fires as this script continues, cleaning it then too.
trap 'rm -f "$DROPIN"' EXIT
logger -t reboot-with-session "writing session image to disk, then rebooting"
systemctl hibernate
