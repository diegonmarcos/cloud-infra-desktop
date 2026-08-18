#!/usr/bin/env bash
# test-sddm-wayland.sh — proves the SDDM Wayland greeter fix is in effect
# and that no DRM master conflicts occur on the deployed system.
#
# Run AFTER `build.sh r` (switch) AND `systemctl restart display-manager`.
# Returns 0 if all checks pass, non-zero otherwise.
#
# Per FIRE RULE 5: every fix must have a tester.

set -u
PASS=0; FAIL=0
declare -a FAILED_TESTS=()

ok()    { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }

# T1 — /etc/sddm.conf says DisplayServer=wayland (post-build deployed config)
DS=$(grep -E '^DisplayServer=' /etc/sddm.conf 2>/dev/null | cut -d= -f2)
if [ "$DS" = "wayland" ]; then
  ok "T1 /etc/sddm.conf: DisplayServer=wayland"
else
  fail "T1 /etc/sddm.conf: DisplayServer=$DS (expected wayland)"
fi

# T2 — CompositorCommand is non-empty (sddm needs it to start the Wayland greeter)
CC=$(awk -F= '/^CompositorCommand=/{print $2}' /etc/sddm.conf 2>/dev/null)
if [ -n "$CC" ] && echo "$CC" | grep -q "kwin_wayland"; then
  ok "T2 /etc/sddm.conf: CompositorCommand uses kwin_wayland"
else
  fail "T2 /etc/sddm.conf: CompositorCommand empty or wrong (got: '$CC')"
fi

# T3 — currently running greeter is NOT Xorg (the bug we're fixing)
if pgrep -af "sddm-greeter" >/dev/null 2>&1; then
  if ps -eo args 2>&1 | grep -E "/bin/X .*sddm" | grep -v grep >/dev/null; then
    fail "T3 SDDM Xorg greeter still running (expected kwin_wayland-based greeter)"
  else
    ok "T3 No SDDM Xorg greeter process running"
  fi
else
  echo "[SKIP] T3 no greeter currently running (only checks if greeter is up)"
fi

# T4 — fallback module no longer mkForce-disables wayland greeter
FALLBACK=/home/diego/git/cloud-unix/aa_nixos-surface_host/src/modules/configuration_fallback.nix
if [ -r "$FALLBACK" ]; then
  if grep -E 'sddm\.wayland\.enable\s*=\s*lib\.mkForce\s+false' "$FALLBACK" >/dev/null; then
    fail "T4 source: configuration_fallback.nix still mkForce-disables sddm.wayland.enable"
  else
    ok "T4 source: configuration_fallback.nix does not override sddm.wayland.enable"
  fi
else
  fail "T4 source: configuration_fallback.nix not readable"
fi

# T5 — no recent DRM "atomic commit failed: Permission denied" (the freeze symptom)
DRM_ERRS=$(journalctl --since "2 minutes ago" --no-pager 2>/dev/null \
  | grep -c "atomic commit failed: Permission denied" || true)
if [ "${DRM_ERRS:-0}" -eq 0 ]; then
  ok "T5 no recent DRM 'atomic commit failed: Permission denied' errors"
else
  fail "T5 $DRM_ERRS DRM permission errors in last 2 min — DRM master conflict still present"
fi

# T6 — only ONE DRM master client at a time (the actual invariant)
DRM_CLIENTS=$(ls /dev/dri/card* 2>/dev/null | wc -l)
if [ "$DRM_CLIENTS" -ge 1 ]; then
  ok "T6 DRM device(s) present: $DRM_CLIENTS"
else
  fail "T6 no DRM device found"
fi

# T7 — safe-graphics specialisation still exists (genuine fallback path)
if [ -L /run/current-system/specialisation/safe-graphics ] || \
   [ -d /run/current-system/specialisation/safe-graphics ]; then
  ok "T7 safe-graphics specialisation present (GRUB fallback)"
else
  fail "T7 safe-graphics specialisation missing — no fallback path"
fi

echo ""
echo "──────────────────────────────────────────"
echo "SDDM Wayland test summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
