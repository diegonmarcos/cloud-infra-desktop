#!/usr/bin/env bash
# test-system-protection-desktop-session.sh — verify the desktop session
# protection module is well-formed and its watchdog behaves correctly.
#
# Run: bash modules/test-system-protection-desktop-session.sh

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$SELF_DIR/system-protection-desktop-session.json"
WATCHDOG="$SELF_DIR/system-protection-desktop-session-watchdog.sh"
NIX_MODULE="$SELF_DIR/system-protection-desktop-session.nix"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

echo "=== desktop-session protection ==="

# ─── PART A: STATIC ────────────────────────────────────────────
[ -r "$JSON" ]       || fail "JSON missing: $JSON"
[ -x "$WATCHDOG" ]   || fail "watchdog not executable: $WATCHDOG"
[ -r "$NIX_MODULE" ] || fail "nix module missing: $NIX_MODULE"
pass "all source files present"

bash -n "$WATCHDOG" || fail "watchdog has syntax errors"
pass "watchdog syntax valid"

jq -e . "$JSON" >/dev/null || fail "JSON does not parse"
pass "JSON parses"

jq -e '.services and .watchdog' "$JSON" >/dev/null \
    || fail "JSON missing required keys (.services, .watchdog)"
pass "JSON schema OK (.services, .watchdog)"

# Each service entry must declare both memory caps + watchdog fields
for svc in $(jq -r '.services | keys[]' "$JSON"); do
    jq -e --arg s "$svc" '
        .services[$s].MemoryHigh and
        .services[$s].MemoryMax  and
        .services[$s].watchdog_warn_mb and
        .services[$s].watchdog_action
    ' "$JSON" >/dev/null \
        || fail "$svc missing required fields (MemoryHigh/MemoryMax/watchdog_warn_mb/watchdog_action)"
    pass "$svc has full schema"
done

# The 4 leak-targets identified in the 2026-04-28 crash MUST be capped
for must in plasma-kwin_wayland.service \
            plasma-plasmashell.service \
            plasma-ksystemstats.service \
            plasma-kded6.service; do
    jq -e --arg s "$must" '.services[$s]' "$JSON" >/dev/null \
        || fail "essential leak-target '$must' is NOT capped"
    pass "leak-target '$must' is capped"
done

# kwin must be 'notify' only — auto-restart tears the session
kwin_action=$(jq -r '.services["plasma-kwin_wayland.service"].watchdog_action' "$JSON")
[ "$kwin_action" = "notify" ] \
    || fail "kwin watchdog_action is '$kwin_action', MUST be 'notify' (restart tears Wayland session)"
pass "kwin uses 'notify' (not 'restart')"

# Nix module must read the JSON and emit user-systemd drop-ins
grep -q 'system-protection-desktop-session.json' "$NIX_MODULE" \
    || fail "nix module doesn't reference the JSON"
pass "nix module references JSON"

grep -q '.config/systemd/user/' "$NIX_MODULE" \
    || fail "nix module doesn't write to .config/systemd/user/"
pass "nix module emits user systemd drop-ins"

grep -q 'systemd.user.timers' "$NIX_MODULE" \
    || fail "nix module doesn't define a user timer"
pass "nix module wires the watchdog timer"

# ─── PART B: BEHAVIOUR ─────────────────────────────────────────
# Watchdog reads CONFIG_JSON env var → run against the source JSON
out=$(CONFIG_JSON="$JSON" "$WATCHDOG" --dry-run --verbose 2>&1)
ec=$?
[ "$ec" = 0 ] || fail "--dry-run exited $ec (out: $out)"
pass "--dry-run exits cleanly"

# Should mention every configured service in verbose output
for svc in $(jq -r '.services | keys[]' "$JSON"); do
    echo "$out" | grep -q "$svc" \
        || fail "--dry-run did not check $svc (out: $out)"
done
pass "--dry-run checks every configured service"

# Must NEVER claim to have restarted anything in dry-run mode
if echo "$out" | grep -q "→ restarted "; then
    fail "--dry-run claims to have restarted a service: $out"
fi
pass "--dry-run does not actually restart"

# Help text works
"$WATCHDOG" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# Bad config path must fail loudly
if CONFIG_JSON=/nonexistent/path.json "$WATCHDOG" --dry-run 2>/dev/null; then
    fail "watchdog accepted nonexistent config (should have errored)"
fi
pass "watchdog rejects missing config"

echo ""
echo "=== desktop-session: PASS ==="
