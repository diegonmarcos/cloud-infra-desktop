#!/usr/bin/env bash
# system-protection-desktop-session-watchdog.sh
#
# Polls memory usage of KDE Plasma services listed in services.json. For each
# service that exceeds its watchdog_warn_mb threshold, performs the configured
# action (restart in-place, or notify only — never auto-restart kwin, that
# tears the Wayland session).
#
# Triggered by: systemd user timer system-protection-desktop-watchdog.timer
# Manual run:   ./system-protection-desktop-session-watchdog.sh --dry-run -v
#
# Config source of truth: $HOME/.config/system-protection-desktop-session/services.json
# Override via:           CONFIG_JSON=/path/to/other.json
#
# Exit codes:
#   0  success (with or without actions)
#   1  config error
#   2  some actions failed

set -u

CONFIG_JSON="${CONFIG_JSON:-$HOME/.config/system-protection-desktop-session/services.json}"

DRY_RUN=false
VERBOSE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --verbose|-v)     VERBOSE=true; shift ;;
        --config)         CONFIG_JSON="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $(basename "$0") [--dry-run] [--verbose] [--config PATH]

Reads the services list from \$CONFIG_JSON and acts on any whose RSS exceeds
the configured warn_mb threshold.

  --dry-run   print planned actions, do not execute
  --verbose   also print services that are healthy
  --config    override config path (default: \$HOME/.config/system-protection-desktop-session/services.json)

Config: $CONFIG_JSON
EOF
            exit 0
            ;;
        *)
            echo "✗ unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

[ -r "$CONFIG_JSON" ] || { echo "✗ config not readable: $CONFIG_JSON" >&2; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "✗ jq required" >&2; exit 1; }
command -v systemctl  >/dev/null 2>&1 || { echo "✗ systemctl required" >&2; exit 1; }

# Read MemoryCurrent of a user systemd unit, in KiB. Returns 0 if not running
# or property unavailable.
unit_memory_kb() {
    local unit="$1" bytes
    bytes=$(systemctl --user show -p MemoryCurrent --value "$unit" 2>/dev/null)
    case "$bytes" in
        ''|'[not set]'|18446744073709551615) echo 0 ;;
        *) echo $((bytes / 1024)) ;;
    esac
}

actions_failed=0
mapfile -t SERVICES < <(jq -r '.services | keys[]' "$CONFIG_JSON")

for svc in "${SERVICES[@]}"; do
    warn_mb=$(jq -r --arg s "$svc" '.services[$s].watchdog_warn_mb // 0' "$CONFIG_JSON")
    action=$(jq  -r --arg s "$svc" '.services[$s].watchdog_action  // "notify"' "$CONFIG_JSON")

    current_kb=$(unit_memory_kb "$svc")
    current_mb=$((current_kb / 1024))
    warn_kb=$((warn_mb * 1024))

    if [ "$current_kb" -lt "$warn_kb" ]; then
        [ "$VERBOSE" = true ] && \
            printf 'OK   %-40s %4dM < %4dM\n' "$svc" "$current_mb" "$warn_mb"
        continue
    fi

    msg="$svc at ${current_mb}M (warn=${warn_mb}M)"
    printf 'WARN %s\n' "$msg"

    if [ "$DRY_RUN" = true ]; then
        printf '     → would %s\n' "$action"
        continue
    fi

    case "$action" in
        notify)
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -u critical "system-protection" "$msg" 2>/dev/null || true
            fi
            command -v logger >/dev/null 2>&1 && \
                logger -t system-protection-desktop "$msg"
            ;;
        restart)
            if systemctl --user restart "$svc" 2>/dev/null; then
                printf '     → restarted %s\n' "$svc"
                command -v logger >/dev/null 2>&1 && \
                    logger -t system-protection-desktop "restarted $svc ($msg)"
            else
                printf '     ✗ restart failed for %s\n' "$svc"
                actions_failed=$((actions_failed + 1))
            fi
            ;;
        *)
            printf '     ✗ unknown action: %s\n' "$action"
            actions_failed=$((actions_failed + 1))
            ;;
    esac
done

[ "$actions_failed" -gt 0 ] && exit 2
exit 0
