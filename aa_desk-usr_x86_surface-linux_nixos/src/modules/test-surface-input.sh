#!/usr/bin/env bash
# test-surface-input.sh — proves the Type Cover click-loss fix state declared
# in hardware_surface.nix matches what is actually running.
#
# Root cause (2026-06-11): SAM firmware reports the FN key as phantom mouse
# button BTN_0 (key 256); stuck BTN_0 breaks clicks on KWin Wayland.
# Fixed by hid-surface driver in linux-surface >= 6.17.13 (PR #1870).
#
# Run AFTER `build.sh s` (switch). Returns 0 if all checks pass.
# Per FIRE RULE 5: every fix claim must have a tester.

set -u
PASS=0; FAIL=0
declare -a FAILED_TESTS=()

ok()    { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
note()  { echo "[NOTE] $1"; }

FIX_VERSION="6.17.13"
KVER=$(uname -r)
KBASE=${KVER%%-*}
# OLD_KERNEL=1 when running kernel predates the hid-surface BTN_0 fix
if [ "$(printf '%s\n%s\n' "$FIX_VERSION" "$KBASE" | sort -V | head -1)" = "$KBASE" ] \
   && [ "$KBASE" != "$FIX_VERSION" ]; then
  OLD_KERNEL=1
  note "kernel $KVER predates the BTN_0 fix ($FIX_VERSION) — stopgap mode expected"
else
  OLD_KERNEL=0
  note "kernel $KVER carries the BTN_0 fix — fixed mode expected"
fi

# T1 — Type Cover keyboard + touchpad enumerated on the SSAM bus
KBD_CAPS=""
for f in /sys/class/input/input*/name; do
  case "$(cat "$f" 2>/dev/null)" in
    *"045E:09AE Keyboard"*) KBD_CAPS="${f%name}capabilities/key" ;;
  esac
done
TP_FOUND=0
grep -qs "045E:09AF Touchpad" /sys/class/input/input*/name 2>/dev/null && TP_FOUND=1
if [ -n "$KBD_CAPS" ] && [ "$TP_FOUND" = "1" ]; then
  ok "T1 Type Cover keyboard (045E:09AE) + touchpad (045E:09AF) enumerated"
else
  fail "T1 Type Cover devices missing (kbd: ${KBD_CAPS:-none}, tp: $TP_FOUND) — cover detached?"
fi

# T2 — BTN_0 phantom button state matches kernel
# capabilities/key words are MSB-first; 5th word from the right = key bits
# 256-319. Bit 0 of that word = BTN_0 (key 256), the stuck FN phantom.
if [ -n "$KBD_CAPS" ] && [ -r "$KBD_CAPS" ]; then
  BTN0_WORD=$(awk '{ print (NF >= 5) ? $(NF-4) : "0" }' "$KBD_CAPS")
  BTN0_BIT=$(( 0x$BTN0_WORD & 1 ))
  if [ "$OLD_KERNEL" = "1" ]; then
    if [ "$BTN0_BIT" = "1" ]; then
      ok "T2 BTN_0 present as expected on unfixed kernel (bug confirmed live)"
    else
      ok "T2 BTN_0 absent on unfixed kernel (unexpected but harmless)"
    fi
  else
    if [ "$BTN0_BIT" = "0" ]; then
      ok "T2 BTN_0 filtered by hid-surface — phantom FN button gone"
    else
      fail "T2 BTN_0 still advertised on fixed kernel — hid-surface not binding"
    fi
  fi
else
  fail "T2 cannot read keyboard key capabilities"
fi

# T3 — hid-surface driver module present in the fixed kernel
if [ "$OLD_KERNEL" = "0" ]; then
  if modinfo hid_surface >/dev/null 2>&1 || grep -qs hid_surface /proc/modules; then
    ok "T3 hid_surface module available"
  else
    fail "T3 hid_surface module missing on >=$FIX_VERSION kernel"
  fi
else
  note "T3 skipped — hid_surface only exists in linux-surface >= $FIX_VERSION"
fi

# T4 — watchdog auto-gate: active stopgap on old kernel, GONE on fixed kernel
WD_STATE=$(systemctl is-active surface-trackpad-watchdog.service 2>/dev/null || true)
if [ "$OLD_KERNEL" = "1" ]; then
  if [ "$WD_STATE" = "active" ]; then
    ok "T4 watchdog stopgap active on unfixed kernel"
  else
    fail "T4 watchdog should be active on unfixed kernel (state: $WD_STATE)"
  fi
else
  if [ "$WD_STATE" = "active" ]; then
    fail "T4 watchdog still active on fixed kernel — version gate broken"
  else
    ok "T4 watchdog auto-disabled on fixed kernel"
  fi
fi

# T5 — kwin_libinput per-event debug spam removed from QT_LOGGING_RULES
if grep -qs "kwin_libinput.debug=true" /etc/set-environment 2>/dev/null; then
  fail "T5 kwin_libinput.debug still in system QT_LOGGING_RULES (journal spam)"
else
  ok "T5 kwin_libinput.debug not in system QT_LOGGING_RULES"
fi

# T6 — pen-stash probe noise (01:15:02:02:00, error -71) is bounded.
# Cosmetic per linux-surface#1845; without the watchdog churning the HID
# stack it should appear only ~once per enumeration, not every 5 minutes.
ERR71_COUNT=$(journalctl -k -b 0 --no-pager 2>/dev/null \
  | grep -c "01:15:02:02:00: probe with driver surface_hid failed" || true)
if [ "$OLD_KERNEL" = "1" ]; then
  note "T6 pen-stash -71 count this boot: $ERR71_COUNT (watchdog resets inflate this; informational)"
else
  if [ "${ERR71_COUNT:-0}" -le 5 ]; then
    ok "T6 pen-stash -71 bounded ($ERR71_COUNT this boot)"
  else
    fail "T6 pen-stash -71 repeating ($ERR71_COUNT this boot) — something still resetting the HID stack"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
