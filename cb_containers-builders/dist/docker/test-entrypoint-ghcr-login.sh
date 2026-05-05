#!/usr/bin/env bash
# test-entrypoint-ghcr-login.sh — verify the cloud-builder entrypoint
# handles the GHCR login step robustly.
#
# Regression: the entrypoint ran `docker login ghcr.io` unconditionally
# inside the container with stderr piped to /dev/null and `set -e` on.
# In CI, the host already authenticates and RO-mounts ~/.docker/config.json
# into the container. The container's `docker login` then tries to write
# back to a RO mount, fails, and `set -e` kills the entrypoint silently
# right after the "[setup] gh CLI config from /mnt/host-gh" line — that
# was the silent exit-1 we saw in run 24960363050 (gen-configs) after
# the vault clone fix unblocked the previous failure.
#
# Required behavior, asserted below:
#   1. If /root/.docker/config.json already has ghcr.io auth → SKIP login.
#   2. If we DO call `docker login`, capture both stderr AND exit status,
#      and treat failure as non-fatal (don't kill the entrypoint).
#   3. Never silence stderr with `2>/dev/null` on `docker login` — silent
#      failures in CI are the worst kind of debug story.

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}/unix"
ENTRY="$REPO/cb_containers-builders/src/docker/entrypoint.sh"
FAILS=0

[ -f "$ENTRY" ] || { echo "✗ $ENTRY not found"; exit 1; }

# 1. RO-mount detection branch present
if grep -q '/root/.docker/config.json.*ghcr.io' "$ENTRY"; then
    echo "✓ entrypoint detects pre-mounted ghcr.io auth and skips re-login"
else
    echo "✗ entrypoint does not detect host-mounted ghcr.io auth — will re-login and crash on RO mount"
    FAILS=$((FAILS + 1))
fi

# 2. docker login failure is treated as non-fatal — wrapped in `if` (or `|| true`)
# Find the GHCR section and assert the docker login is in a conditional, not bare.
ghcr_block=$(awk '/^# ── 5\. GHCR login/,/^# ──/' "$ENTRY" | head -30)
bare_login=$(printf '%s\n' "$ghcr_block" | grep -E '^\s*echo .* \| docker login' | grep -v '^\s*if ' || true)
if [ -n "$bare_login" ]; then
    echo "✗ bare 'docker login' found (not in if/||) — failure will kill entrypoint under set -e:"
    printf '%s\n' "$bare_login" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    echo "✓ docker login is wrapped in conditional — failures are caught"
fi

# 3. No `2>/dev/null` on `docker login` itself (post-command). Stderr from
# upstream pipeline stages — gh auth token, echo — is allowed to be silenced;
# only the docker login process's own stderr must stay visible.
silenced=$(grep -E -e '--password-stdin\s*2>/dev/null' "$ENTRY" || true)
if [ -n "$silenced" ]; then
    echo "✗ docker login itself silences stderr (2>/dev/null) — silent failures hide the real cause:"
    printf '%s\n' "$silenced" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    echo "✓ docker login keeps its own stderr visible"
fi

# 4. Comment block explains WHY (the regression context) so future-you doesn't
# revert this fix without understanding it.
if grep -q "RO mount\|RO-mount\|read-only mount" "$ENTRY"; then
    echo "✓ entrypoint comment explains the RO-mount issue"
else
    echo "✗ entrypoint missing comment about the RO-mount root cause — risk of regression"
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-entrypoint-ghcr-login: PASS"
    exit 0
else
    echo "test-entrypoint-ghcr-login: FAIL ($FAILS check(s))"
    exit 1
fi
