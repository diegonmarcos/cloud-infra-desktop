#!/usr/bin/env bash
# nix-switch-progressbar — a REAL graphical progress bar for a build.sh switch
# (yad --progress): overall %, current phase/step, live download rate + ETA,
# and a Cancel button that stops the switch. Driven off build.log phase lines
# and the dist-ci download size. Spawned by build.sh's switch isolation block.
#
# Args: $1 = build.log path, $2 = dist-ci artifact dir, $3 = switch systemd unit
#       to stop on Cancel.
set -uo pipefail
LOG="${1:-$HOME/git/unix/ba_flakes_desktop/build.log}"
ART="${2:-$HOME/git/unix/ba_flakes_desktop/dist-ci}"
UNIT="${3:-hm-switch-isolated.service}"

command -v yad >/dev/null 2>&1 || exec tail -f "$LOG"   # headless fallback

# Expected download size (MB), parsed from the log's "(~NNNNMB)" line.
EXP=$(grep -oE '~[0-9]+MB' "$LOG" 2>/dev/null | tail -1 | tr -dc '0-9')
EXP=${EXP:-6339}
START=$(date +%s)

unit_active() {
  systemctl --user is-active "$UNIT" >/dev/null 2>&1 && return 0
  systemctl is-active "$UNIT" >/dev/null 2>&1
}

driver() {
  local tailtxt phase pct mb el rate rem
  while :; do
    tailtxt=$(tail -8 "$LOG" 2>/dev/null)
    if   echo "$tailtxt" | grep -qiE "SWITCH SUCCEEDED|Activation.*complete|activated successfully|home-manager.*activated"; then
         echo 100; echo "# Switch complete — new generation activated"; break
    elif echo "$tailtxt" | grep -qiE "Activating|/activate"; then
         phase="Activating new generation..."; pct=94
    elif echo "$tailtxt" | grep -qiE "Import|nix-store --import|materialis"; then
         phase="Importing closure into /nix/store..."; pct=82
    elif echo "$tailtxt" | grep -qiE "Downloading"; then
         mb=$(du -sm "$ART" 2>/dev/null | awk '{print $1}'); mb=${mb:-0}
         pct=$(( mb * 70 / (EXP>0?EXP:6339) + 6 )); [ "$pct" -gt 78 ] && pct=78
         el=$(( $(date +%s) - START )); rate=$(( el>0 ? mb/el : 0 ))
         rem=$(( rate>0 ? (EXP-mb)/rate : 0 ))
         phase="Downloading ${mb}/${EXP} MB - ${rate} MB/s - ETA $((rem/60))m$((rem%60))s"
    else phase="Preparing (resolving GHA closure)..."; pct=3
    fi
    echo "$pct"; echo "# $phase"
    unit_active || { echo 100; echo "# Finished"; break; }
    sleep 2
  done
}

driver | yad --progress --title="NixOS Switch - live progress" \
  --width=600 --height=140 --center --on-top \
  --image=system-software-update --text="Activating a new home-manager generation" \
  --percentage=0 --auto-close --auto-kill \
  --button="Cancel switch!process-stop:1" --button="Hide!window-close:0"
rc=$?
if [ "$rc" = 1 ]; then
  systemctl --user stop "$UNIT" 2>/dev/null || systemctl stop "$UNIT" 2>/dev/null || true
  command -v notify-send >/dev/null 2>&1 && notify-send -u critical "NixOS switch cancelled" "You cancelled the switch." || true
fi
