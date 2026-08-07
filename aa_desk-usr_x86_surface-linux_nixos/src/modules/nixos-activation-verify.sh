#!/usr/bin/env bash
# nixos-activation-verify.sh — post-activation invariant checks.
# See configuration_activation_verify.nix for the full incident history
# (POST-INCIDENT 2026-05-16) and activation wiring.
#
# Fully runtime-data-driven: the list of human users that must exist in
# /etc/shadow with a real password hash, and the list of paths that must
# exist after activation, are read at RUNTIME from CONFIG_JSON
# (/etc/cloud-data/activation-verify.json) via jq. Nothing is baked in by
# Nix interpolation.
set -u

CONFIG_JSON="${ACTIVATION_VERIFY_JSON:-/etc/cloud-data/activation-verify.json}"

problems=()

# This check runs DEAD LAST in activation and exists to catch activation
# lying about success. A missing/unparseable config here means we cannot
# verify anything — that is itself a problem worth screaming about, so it
# is recorded like any other finding rather than silently exiting 0.
if [ ! -r "$CONFIG_JSON" ]; then
  problems+=("ACTIVATION-VERIFY CONFIG MISSING/UNREADABLE: $CONFIG_JSON — cannot verify required paths/users")
  requiredPaths=()
  requiredHumanUsers=()
elif ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  problems+=("ACTIVATION-VERIFY CONFIG UNPARSEABLE: $CONFIG_JSON — cannot verify required paths/users")
  requiredPaths=()
  requiredHumanUsers=()
else
  mapfile -t requiredPaths < <(jq -r '.required_paths[]? // empty' "$CONFIG_JSON")
  mapfile -t requiredHumanUsers < <(jq -r '.required_human_users[]? // empty' "$CONFIG_JSON")
fi

# ── 1. Critical paths exist ─────────────────────────────────────────
for p in "${requiredPaths[@]:-}"; do
  [ -n "$p" ] || continue
  if [ ! -e "$p" ]; then
    problems+=("MISSING PATH: $p")
  fi
done

# ── 2. Human users in /etc/shadow with REAL hash ────────────────────
for u in "${requiredHumanUsers[@]:-}"; do
  [ -n "$u" ] || continue
  line=$(grep "^${u}:" /etc/shadow 2>/dev/null || true)
  if [ -z "$line" ]; then
    problems+=("USER MISSING FROM /etc/shadow: ${u} — login will fail")
  else
    hash=$(echo "$line" | cut -d: -f2)
    case "$hash" in
      \$*)  : ;;  # real $6$... hash → ok
      "!"*) problems+=("USER LOCKED in /etc/shadow: ${u} — login will fail") ;;
      "*")  problems+=("USER HAS NO PASSWORD in /etc/shadow: ${u}") ;;
      "")   problems+=("USER HAS EMPTY hash field in /etc/shadow: ${u}") ;;
      *)    problems+=("USER ${u} has unrecognised hash format in /etc/shadow: ${hash:0:8}...") ;;
    esac
  fi
done

# ── 3. swap is on a non-pool filesystem (per 2026-05-15 incident) ───
# If swapDevices is configured AND the swap file is on btrfs, scream.
if grep -q "^/" /proc/swaps 2>/dev/null; then
  while read -r dev rest; do
    [ "${dev:0:1}" = "/" ] || continue
    fs=$(findmnt -no FSTYPE -T "$dev" 2>/dev/null || echo "unknown")
    if [ "$fs" = "btrfs" ]; then
      problems+=("SWAP ON BTRFS: $dev — see incident 2026-05-15")
    fi
  done < /proc/swaps
fi

# ── REPORT ──────────────────────────────────────────────────────────
if [ ${#problems[@]} -eq 0 ]; then
  logger -t nixos-activation-verify -p user.info \
    "all ${#requiredHumanUsers[@]} human users present, all ${#requiredPaths[@]} critical paths exist, swap not on btrfs"
  exit 0
fi

# FAIL — loud broadcast on every channel.
banner="
╔══════════════════════════════════════════════════════════════════╗
║   NIXOS ACTIVATION VERIFY: $(printf '%2d' "${#problems[@]}") PROBLEM(S) DETECTED            ║
╠══════════════════════════════════════════════════════════════════╣"
msg="$banner"
for p in "${problems[@]}"; do
  msg="$msg
║   • $p"
done
msg="$msg
╚══════════════════════════════════════════════════════════════════╝"

echo "$msg" >&2
echo "$msg" | wall -n 2>/dev/null || true
for p in "${problems[@]}"; do
  logger -t nixos-activation-verify -p user.crit "$p"
done

# Append to /etc/motd so login banner shows it.
{
  echo
  echo "$msg"
  echo
} >> /etc/motd 2>/dev/null || true

exit 1
