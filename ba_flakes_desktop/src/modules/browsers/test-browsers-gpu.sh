#!/usr/bin/env bash
# test-browsers-gpu.sh — Verify GPU wrapper produces zero GPU init errors.
#
# Source of truth: ./browsers-gpu.json
# For each declared browser whose binary is on PATH, launch it briefly in
# an isolated profile and grep stderr for the known GPU-init failure
# markers. Pass = no markers found.
#
# Run after a home-manager switch:
#   bash ~/git/cloud-infra-desktop/ba_flakes_desktop/src/modules/test-browsers-gpu.sh
#
set -euo pipefail

JSON="$(dirname "$(readlink -f "$0")")/browsers-gpu.json"
[ -f "$JSON" ] || { echo "FAIL: $JSON not found"; exit 2; }

# Failure markers from probe runs 2026-04-29
FAIL_RE='Failed to find drm render node path|eglCreateContext: Requested version is not supported|Compositing.*Software only|GPU.*compositing.*disabled|EGL_NOT_INITIALIZED|Internal Vulkan error'

declare -i ok=0 fail=0 skip=0

for browser in $(jq -r '.browsers | keys[]' "$JSON"); do
  if ! command -v "$browser" >/dev/null 2>&1; then
    echo "[SKIP] $browser — not installed"
    skip=$((skip + 1))
    continue
  fi

  tmp=$(mktemp -d -p /tmp "test-browsers-gpu-$browser-XXXX")
  log="$tmp/stderr.log"

  # Wrapped binary already includes the GPU flags via wrapProgram --add-flags.
  # We just launch it; if the wrapper applied correctly, no failure markers
  # should appear in stderr.
  timeout 8 "$browser" \
    --user-data-dir="$tmp" \
    --no-first-run --no-default-browser-check \
    --enable-logging=stderr --v=0 \
    about:blank >/dev/null 2>"$log" || true

  if grep -qE "$FAIL_RE" "$log"; then
    echo "[FAIL] $browser — GPU failure markers present:"
    grep -E "$FAIL_RE" "$log" | sed 's/^/         /' | head -3
    fail=$((fail + 1))
  else
    echo "[ OK ] $browser — no GPU failure markers"
    ok=$((ok + 1))
  fi

  # `|| true` — brave's lockfiles sometimes lag behind SIGTERM; cleanup
  # failure is cosmetic, must not abort the test loop under `set -e`.
  rm -rf "$tmp" 2>/dev/null || true
done

echo ""
echo "Summary: ok=$ok fail=$fail skip=$skip"
[ $fail -eq 0 ]
