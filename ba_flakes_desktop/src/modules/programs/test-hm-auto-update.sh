#!/usr/bin/env bash
# test-hm-auto-update.sh — verify hm-auto-update-check: seeds a baseline on
# first run without switching, no-ops on an unchanged digest, and fires
# `systemd-run --user --unit=hm-auto-switch ... switch` on a changed digest.
# Exercises the REAL script (programs/hm-auto-update-check.sh — the source of
# truth read at RUNTIME by the writeShellApplication wired in
# programs/hm-auto-update.nix, not a hand-copied duplicate) against stub
# gh/skopeo/systemd-run/notify-send on PATH and a stub CONFIG_JSON — no
# network, no real switch.
#
# Run: bash modules/programs/test-hm-auto-update.sh

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "FAIL: $1" >&2; cleanup_test; exit 1; }
pass() { echo "  ✓ $1"; }

TMP_DIR=""
cleanup_test() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup_test EXIT INT TERM

echo "=== hm-auto-update-check ==="

command -v jq >/dev/null 2>&1 || fail "jq not found — the script reads its config via jq"

TMP_DIR="$(mktemp -d -t test-hm-auto-update.XXXXXX)"
SCRIPT="$SELF_DIR/hm-auto-update-check.sh"
CONFIG_JSON="$TMP_DIR/hm-auto-update.json"
BIN_DIR="$TMP_DIR/bin"
STATE_DIR="$TMP_DIR/state"
SWITCH_LOG="$TMP_DIR/switch-calls.log"
mkdir -p "$BIN_DIR" "$STATE_DIR"
: > "$SWITCH_LOG"

[ -s "$SCRIPT" ] || fail "hm-auto-update-check.sh not found next to this test"
pass "found the real hm-auto-update-check.sh"

bash -n "$SCRIPT" || fail "script has syntax errors"
pass "script syntax valid"

# Stub CONFIG_JSON: only the fields the script has NO HAU_* env override for
# (notify_send channel, switch cgroup bounds) matter here — the rest are
# overridden per-run below, but jq still needs every key present.
cat > "$CONFIG_JSON" <<'EOF'
{
  "image": "test/image",
  "tag": "test",
  "repo_build_sh": "/nonexistent/build.sh",
  "safety": { "min_free_mb": 0, "switch_memory_max": "4G", "switch_swap_max": "4G" },
  "countdown": {
    "delay_seconds": 0,
    "channels": { "dialog_center": false, "notify_send": true }
  }
}
EOF

# ── stub PATH: gh, skopeo, systemd-run, notify-send ─────────────────────
cat > "$BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = auth ] && [ "$2" = token ] && { echo "faketoken"; exit 0; }
exit 1
EOF
cat > "$BIN_DIR/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN_DIR/systemd-run" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SWITCH_LOG"
exit 0
EOF
chmod +x "$BIN_DIR"/gh "$BIN_DIR"/notify-send "$BIN_DIR"/systemd-run

skopeo_stub() {
    local digest="$1"
    cat > "$BIN_DIR/skopeo" <<EOF
#!/usr/bin/env bash
echo "$digest"
exit 0
EOF
    chmod +x "$BIN_DIR/skopeo"
}

# yad stub with a controllable exit code (simulates the countdown dialog:
# 0=Switch now, 1=Skip this build, 70=timeout/auto-proceed).
YAD_LOG="$TMP_DIR/yad-calls.log"
yad_stub() {
    local rc="$1"
    cat > "$BIN_DIR/yad" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$YAD_LOG"
exit $rc
EOF
    chmod +x "$BIN_DIR/yad"
}

# Default: headless (no dialog), zero countdown, RAM guard disabled
# (HAU_MIN_FREE_MB=0) so the guard never defers on a low-RAM test box.
run_check() {
    PATH="$BIN_DIR:$PATH" \
    HAU_CONFIG_JSON="$CONFIG_JSON" \
    HAU_STATE_DIR="$STATE_DIR" \
    HAU_BUILD_SH="/nonexistent/build.sh" \
    HAU_IMAGE="test/image" HAU_TAG="test" \
    HAU_DIALOG=0 HAU_DELAY=0 HAU_MIN_FREE_MB=0 \
    bash "$SCRIPT"
}

# Dialog path: force a graphical session + enable the dialog; yad_stub decides.
run_check_dialog() {
    PATH="$BIN_DIR:$PATH" \
    HAU_CONFIG_JSON="$CONFIG_JSON" \
    HAU_STATE_DIR="$STATE_DIR" \
    HAU_BUILD_SH="/nonexistent/build.sh" \
    HAU_IMAGE="test/image" HAU_TAG="test" \
    HAU_DIALOG=1 HAU_DELAY=0 HAU_MIN_FREE_MB=0 DISPLAY=":0" \
    bash "$SCRIPT"
}

# RAM-guard path: impossibly high floor → must DEFER (no switch, no digest record).
run_check_lowram() {
    PATH="$BIN_DIR:$PATH" \
    HAU_CONFIG_JSON="$CONFIG_JSON" \
    HAU_STATE_DIR="$STATE_DIR" \
    HAU_BUILD_SH="/nonexistent/build.sh" \
    HAU_IMAGE="test/image" HAU_TAG="test" \
    HAU_DIALOG=0 HAU_DELAY=0 HAU_MIN_FREE_MB=999999999 \
    bash "$SCRIPT"
}

# ── first run: seeds baseline, does NOT switch ──────────────────────────
skopeo_stub "sha256:aaaa"
run_check || fail "first run exited non-zero"
[ -f "$STATE_DIR/last-digest" ] || fail "first run did not seed last-digest"
[ "$(cat "$STATE_DIR/last-digest")" = "sha256:aaaa" ] || fail "seeded digest mismatch"
[ ! -s "$SWITCH_LOG" ] || fail "first run triggered a switch (should only seed)"
pass "first run seeds baseline digest, no switch"

# ── unchanged digest: no-op, no switch ───────────────────────────────────
run_check || fail "unchanged-digest run exited non-zero"
[ ! -s "$SWITCH_LOG" ] || fail "unchanged digest triggered a switch"
pass "unchanged digest is a no-op"

# ── changed digest: triggers systemd-run switch ──────────────────────────
skopeo_stub "sha256:bbbb"
run_check || fail "changed-digest run exited non-zero"
[ "$(cat "$STATE_DIR/last-digest")" = "sha256:bbbb" ] || fail "digest file not updated"
grep -q "hm-auto-switch" "$SWITCH_LOG" || fail "changed digest did not fire systemd-run --unit=hm-auto-switch"
grep -q "/nonexistent/build.sh switch" "$SWITCH_LOG" || fail "systemd-run did not target build.sh switch"
pass "changed digest fires systemd-run --unit=hm-auto-switch ... build.sh switch"

# ── headless changed digest already covered above (run_check = headless) ──
# It fired the switch with no dialog → proves the headless-proceed path.
pass "headless changed digest proceeds without a dialog (covered above)"

# ── dialog: 'Skip this build' (yad rc=1) → digest recorded, NO switch ─────
skopeo_stub "sha256:cccc"
yad_stub 1
: > "$SWITCH_LOG"; : > "$YAD_LOG"
run_check_dialog || fail "dialog-skip run exited non-zero"
[ "$(cat "$STATE_DIR/last-digest")" = "sha256:cccc" ] || fail "skip must still record the digest (no re-prompt loop)"
[ -s "$YAD_LOG" ] || fail "dialog was not shown"
[ ! -s "$SWITCH_LOG" ] || fail "'Skip this build' still triggered a switch"
pass "dialog 'Skip this build' records digest, does NOT switch"

# ── dialog: 'Switch now' (yad rc=0) → switch fires ───────────────────────
skopeo_stub "sha256:dddd"
yad_stub 0
: > "$SWITCH_LOG"; : > "$YAD_LOG"
run_check_dialog || fail "dialog-switch-now run exited non-zero"
[ -s "$YAD_LOG" ] || fail "dialog was not shown"
grep -q "hm-auto-switch" "$SWITCH_LOG" || fail "'Switch now' did not fire the switch"
pass "dialog 'Switch now' fires the switch"

# ── dialog: timeout (yad rc=70) → proceed (auto) ─────────────────────────
skopeo_stub "sha256:eeee"
yad_stub 70
: > "$SWITCH_LOG"; : > "$YAD_LOG"
run_check_dialog || fail "dialog-timeout run exited non-zero"
grep -q "hm-auto-switch" "$SWITCH_LOG" || fail "countdown timeout did not auto-proceed to switch"
pass "dialog countdown timeout auto-proceeds to switch"

# ── RAM guard: low free RAM must DEFER (no switch, digest NOT recorded) ──
# Prove the exact fix for the 13:41 bootstrap freeze: never fire a heavy
# switch when the desktop is memory-full.
echo "sha256:ffff" > "$STATE_DIR/last-digest"   # known baseline
skopeo_stub "sha256:9999"                        # a new digest is available
: > "$SWITCH_LOG"
run_check_lowram || fail "low-RAM run should exit 0 (soft-defer), not fail"
[ ! -s "$SWITCH_LOG" ] || fail "low RAM must NOT trigger a switch (would freeze the box)"
[ "$(cat "$STATE_DIR/last-digest")" = "sha256:ffff" ] || fail "defer must NOT record the new digest (so next poll retries)"
pass "low free RAM DEFERS the switch, digest not recorded (retries next poll)"

# ── skopeo unavailable (registry down / not yet pushed): skip, no crash ──
cat > "$BIN_DIR/skopeo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN_DIR/skopeo"
: > "$SWITCH_LOG"
run_check || fail "skopeo-failure run should exit 0 (soft-skip), not fail"
[ ! -s "$SWITCH_LOG" ] || fail "skopeo failure should never trigger a switch"
pass "skopeo/registry failure soft-skips (no crash, no switch)"

echo ""
echo "=== hm-auto-update-check: PASS ==="
