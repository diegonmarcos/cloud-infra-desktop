#!/usr/bin/env bash
# test-htop-dashboard.sh — verify the declarative 5-tab htop dashboard.
#
# Validates that home-manager renders ~/.config/htop/htoprc with:
#   • 5 named screens: MAIN, CPU, MEMORY, DISK, GPU
#   • each screen has a sensible sort_key for its purpose
#   • header layout = four (max info density)
#   • PSI pressure meters (Pressure_CPU/Memory/IO) on the header
#   • CPU detailed time + frequency + temperature meters enabled
#
# SOURCE check tolerates the home-manager switch not having run yet
# (LIVE older than SRC = warning, not failure).

set -euo pipefail

SRC="${BASH_SOURCE[0]%/*}/plasma.nix"
LIVE="$HOME/.config/htop/htoprc"
FAILS=0

[ -f "$SRC" ] || { echo "✗ source plasma.nix missing"; exit 1; }
echo "✓ source plasma.nix found"

section() {
    awk '/xdg.configFile."htop\/htoprc"\.text = ..$/,/^  ..;/' "$SRC"
}

# 1. Five named screens
for s in MAIN CPU MEMORY DISK GPU; do
    if section | grep -qE "^[[:space:]]*screen:${s}="; then
        echo "✓ SOURCE: screen:${s} declared"
    else
        echo "✗ SOURCE: screen:${s} missing"
        FAILS=$((FAILS + 1))
    fi
done

# 2. Each screen has a relevant sort key (test by reading the sort_key
# line that immediately follows screen:NAME=)
declare -A EXPECTED_SORT=(
    [MAIN]=PERCENT_CPU
    [CPU]=PERCENT_CPU
    [MEMORY]=M_RESIDENT
    [DISK]=IO_RATE
    [GPU]=PERCENT_GPU
)
for s in "${!EXPECTED_SORT[@]}"; do
    expected="${EXPECTED_SORT[$s]}"
    actual=$(section | awk -v scr="screen:${s}=" '$0 ~ scr {found=1; next} found && /^[[:space:]]*\.sort_key=/ {print; exit}' | sed 's/.*sort_key=//')
    if [ "$actual" = "$expected" ]; then
        echo "✓ SOURCE: ${s} sorts by ${expected}"
    else
        echo "✗ SOURCE: ${s} expected sort=${expected} got '${actual}'"
        FAILS=$((FAILS + 1))
    fi
done

# 3. Header layout + PSI meters
if section | grep -qE '^[[:space:]]*header_layout=four'; then
    echo "✓ SOURCE: header_layout=four (max info density)"
else
    echo "✗ SOURCE: header_layout != four"
    FAILS=$((FAILS + 1))
fi

# Per-core bars (NOT AllCPUs2/4 which collapse cores). With 8 cores +
# detailed_cpu_time=1, AllCPUs in mode 1 (Bar) gives one stacked bar per
# core with user/sys/irq/iowait/guest colors split.
if section | grep -qE '^[[:space:]]*column_meters_0=AllCPUs(\b|[[:space:]])'; then
    echo "✓ SOURCE: col 0 uses AllCPUs (one bar per core, all 8 visible)"
else
    echo "✗ SOURCE: col 0 not using plain AllCPUs — cores will be collapsed"
    FAILS=$((FAILS + 1))
fi
if section | grep -qE '^[[:space:]]*column_meter_modes_0=1\b'; then
    echo "✓ SOURCE: col 0 mode = 1 (Bar) — green/red/blue per-core split visible"
else
    echo "✗ SOURCE: col 0 not in Bar mode (mode 1) — color breakdown lost"
    FAILS=$((FAILS + 1))
fi
for meter in Pressure_CPU Pressure_Memory Pressure_IO; do
    if section | grep -qF "$meter"; then
        echo "✓ SOURCE: header has $meter"
    else
        echo "✗ SOURCE: header missing $meter"
        FAILS=$((FAILS + 1))
    fi
done

# 4. CPU detail flags ON (frequency + temperature + detailed time)
for flag in 'detailed_cpu_time=1' 'show_cpu_frequency=1' 'show_cpu_temperature=1'; do
    if section | grep -qE "^[[:space:]]*${flag}\b"; then
        echo "✓ SOURCE: ${flag}"
    else
        echo "✗ SOURCE: ${flag} not set"
        FAILS=$((FAILS + 1))
    fi
done

# 5. screen_tabs=1 (visible tab bar)
if section | grep -qE '^[[:space:]]*screen_tabs=1'; then
    echo "✓ SOURCE: screen_tabs=1 (visible tab bar)"
else
    echo "✗ SOURCE: screen_tabs not enabled"
    FAILS=$((FAILS + 1))
fi

# 6. MAIN tab carries the full PSI suite — per-process CPU/IO/swap delay,
# page faults, IO rate, GPU. The MAIN tab is "show me everything in one
# row" (other tabs are filtered views), so all PSI signals must be there.
MAIN_LINE=$(section | grep '^[[:space:]]*screen:MAIN=' | head -1)
for col in PERCENT_CPU_DELAY PERCENT_IO_DELAY PERCENT_SWAP_DELAY MAJFLT MINFLT IO_RATE PERCENT_GPU NLWP M_PSS M_SWAP; do
    if echo "$MAIN_LINE" | grep -qE "[[:space:]=]${col}[[:space:]]"; then
        echo "✓ SOURCE: MAIN tab includes $col"
    else
        echo "✗ SOURCE: MAIN tab missing $col"
        FAILS=$((FAILS + 1))
    fi
done

# 6. LIVE parity (warn-only if not deployed yet)
if [ -L "$LIVE" ] || [ -f "$LIVE" ]; then
    src_mtime=$(stat -c%Y "$SRC")
    live_mtime=$(stat -Lc%Y "$LIVE")
    if [ "$live_mtime" -ge "$src_mtime" ] && grep -qE '^[[:space:]]*screen:GPU=' "$LIVE"; then
        echo "✓ LIVE: ~/.config/htop/htoprc has the 5 screens"
    else
        echo "ℹ LIVE: $LIVE older than source OR missing screens — run ba_flakes_desktop/build.sh switch"
    fi
else
    echo "ℹ LIVE: $LIVE missing — run build.sh switch to deploy"
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-htop-dashboard: PASS"
    exit 0
else
    echo "test-htop-dashboard: FAIL ($FAILS check(s))"
    exit 1
fi
