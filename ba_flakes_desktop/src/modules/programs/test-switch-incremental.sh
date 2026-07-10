#!/usr/bin/env bash
# test-switch-incremental.sh — prove the incremental-first switch path
# (ghcr_incremental_switch in build.sh) does what the whole layered-cache
# design exists for: read the activation store path from a KB-sized `skopeo
# inspect` label and NEVER fall back to the ~6GB `gh run download` artifact
# when the label + store path are available. Sources build.sh functions with
# BUILDSH_SOURCE_ONLY=1 (no dispatcher, no re-exec) and stubs skopeo/gh/docker.
#
# Run: bash modules/programs/test-switch-incremental.sh

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SH="$(cd "$SELF_DIR/../../.." && pwd)/build.sh"

fail() { echo "FAIL: $1" >&2; cleanup_test; exit 1; }
pass() { echo "  ✓ $1"; }

TMP_DIR=""
cleanup_test() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup_test EXIT INT TERM

echo "=== ghcr_incremental_switch (no-big-download) ==="

[ -f "$BUILD_SH" ] || fail "build.sh not found at $BUILD_SH"

TMP_DIR="$(mktemp -d -t test-switch-incr.XXXXXX)"
BIN_DIR="$TMP_DIR/bin"; mkdir -p "$BIN_DIR"
ART="$TMP_DIR/dist-ci"
DOWNLOAD_TRIPWIRE="$TMP_DIR/gh-download-was-called"
DOCKER_TRIPWIRE="$TMP_DIR/docker-was-called"

# Source ONLY the functions (guarded dispatcher/re-exec/main do not run).
BUILDSH_SOURCE_ONLY=1 . "$BUILD_SH" || fail "could not source build.sh functions"
command -v ghcr_incremental_switch >/dev/null 2>&1 || fail "ghcr_incremental_switch not defined after source"
pass "sourced build.sh functions (no dispatcher ran)"

# ── stubs ────────────────────────────────────────────────────────────────
# gh: 'auth token' works; 'run download' trips the wire + fails the test's
# intent (it must never be reached on the incremental path).
cat > "$BIN_DIR/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = auth ] && [ "\$2" = token ]; then echo "faketoken"; exit 0; fi
if [ "\$1" = run ] && [ "\$2" = download ]; then touch "$DOWNLOAD_TRIPWIRE"; exit 1; fi
exit 1
EOF
# docker: any call trips the wire (proves layered pull was/ wasn't invoked).
cat > "$BIN_DIR/docker" <<EOF
#!/usr/bin/env bash
touch "$DOCKER_TRIPWIRE"
exit 1
EOF
chmod +x "$BIN_DIR/gh" "$BIN_DIR/docker"

# skopeo stub: emits a controllable label value for `inspect --format ...`.
skopeo_label() {
    cat > "$BIN_DIR/skopeo" <<EOF
#!/usr/bin/env bash
# only the inspect --format path is used by ghcr_incremental_switch
echo "$1"
exit 0
EOF
    chmod +x "$BIN_DIR/skopeo"
}

run_incr() { PATH="$BIN_DIR:$PATH" ghcr_incremental_switch "$ART"; }

# ── A. label present + store path already present → rc 0, no download, no docker
FAKE_SYS="$TMP_DIR/store/abcdef123-hm"; mkdir -p "$FAKE_SYS"
rm -rf "$ART"; rm -f "$DOWNLOAD_TRIPWIRE" "$DOCKER_TRIPWIRE"
skopeo_label "$FAKE_SYS"
run_incr || fail "A: healthy label+present-path should return 0"
[ -f "$ART/activation.name" ] || fail "A: activation.name not written"
[ "$(cat "$ART/activation.name")" = "abcdef123-hm" ] || fail "A: activation.name should be the store path basename"
[ ! -f "$DOWNLOAD_TRIPWIRE" ] || fail "A: gh run download WAS called — incremental path must never download the artifact"
[ ! -f "$DOCKER_TRIPWIRE" ] || fail "A: docker/ghcr_pull_layered called though path already present"
pass "A: label + present path → rc0, activation.name written, NO artifact download, NO layered pull"

# ── B. image carries no label (predates labeled builds) → rc 1 (fallback)
rm -rf "$ART"; rm -f "$DOWNLOAD_TRIPWIRE" "$DOCKER_TRIPWIRE"
skopeo_label "<no value>"
if run_incr; then fail "B: unlabeled image should return non-zero (fall back to download)"; fi
[ ! -f "$DOWNLOAD_TRIPWIRE" ] || fail "B: ghcr_incremental_switch itself must not download — the CALLER does the fallback"
pass "B: unlabeled image → rc1 (caller falls back to artifact download)"

# ── C. gh not authenticated → rc 1 (fallback), never touches skopeo result
cat > "$BIN_DIR/gh" <<EOF
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN_DIR/gh"
rm -rf "$ART"
skopeo_label "$FAKE_SYS"
if run_incr; then fail "C: gh-auth failure should return non-zero"; fi
pass "C: gh not authenticated → rc1 (fallback)"

echo ""
echo "=== ghcr_incremental_switch: PASS ==="
