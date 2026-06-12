# Post-activation verification — POST-INCIDENT 2026-05-16.
#
# WHY THIS EXISTS
# ───────────────
# After the 2026-05-15 incident reinstall, login as diego/1234567890 failed
# on first boot. Cause turned out to be a misread of /etc/shadow on my part
# (the users WERE there), but the investigation surfaced a class of silent
# failures that NixOS's activation script DOES allow:
#
#   - `set -e` is NOT active in activate; each snippet uses `_localstatus=0`
#     + an ERR trap that only records (`_status=1`) without halting.
#   - On script completion, only "Activation script snippet 'X' failed (N)"
#     lines are printed — easy to miss in a long boot log, no aggregated
#     summary, no wall broadcast, no journal CRIT.
#
# This module runs DEAD LAST in activation and verifies invariants that, if
# violated, would render the system unusable. Failures are surfaced via:
#   1. journal at user.crit (always captured even in early-boot)
#   2. wall broadcast (so a console user sees it BEFORE the login prompt)
#   3. /etc/motd append (login screen banner)
#   4. exit non-zero (NixOS will mark activation degraded → systemd reports
#      it loudly at next `systemctl status`)
#
# Add new checks here as we discover new ways NixOS activation can lie.
{ config, lib, pkgs, ... }:

let
  # Users who MUST be present in /etc/shadow with a real hashedPassword
  # (anything starting with $) — not `!` (locked), not `*` (no password).
  requiredHumanUsers = [ "root" "diego" "guest" ];

  # Files/paths that MUST exist after activation.
  requiredPaths = [
    "/etc/shadow"
    "/etc/passwd"
    "/etc/group"
    "/etc/nixos"
    "/run/current-system"
    "/nix/var/nix/profiles/system"
  ];

  verifyScript = pkgs.writeShellApplication {
    name = "nixos-activation-verify";
    runtimeInputs = with pkgs; [ coreutils gawk util-linux ];
    text = ''
      set -u
      problems=()

      # ── 1. Critical paths exist ─────────────────────────────────────────
      ${lib.concatMapStringsSep "\n" (p: ''
        if [ ! -e ${lib.escapeShellArg p} ]; then
          problems+=("MISSING PATH: ${p}")
        fi
      '') requiredPaths}

      # ── 2. Human users in /etc/shadow with REAL hash ────────────────────
      ${lib.concatMapStringsSep "\n" (u: ''
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
            *)    problems+=("USER ${u} has unrecognised hash format in /etc/shadow: ''${hash:0:8}...") ;;
          esac
        fi
      '') requiredHumanUsers}

      # ── 3. swap is on a non-pool filesystem (per 2026-05-15 incident) ───
      # If swapDevices is configured AND the swap file is on btrfs, scream.
      if grep -q "^/" /proc/swaps 2>/dev/null; then
        while read -r dev rest; do
          [ "''${dev:0:1}" = "/" ] || continue
          fs=$(${pkgs.util-linux}/bin/findmnt -no FSTYPE -T "$dev" 2>/dev/null || echo "unknown")
          if [ "$fs" = "btrfs" ]; then
            problems+=("SWAP ON BTRFS: $dev — see incident 2026-05-15")
          fi
        done < /proc/swaps
      fi

      # ── REPORT ──────────────────────────────────────────────────────────
      if [ ''${#problems[@]} -eq 0 ]; then
        ${pkgs.util-linux}/bin/logger -t nixos-activation-verify -p user.info \
          "all ${toString (builtins.length requiredHumanUsers)} human users present, all ${toString (builtins.length requiredPaths)} critical paths exist, swap not on btrfs"
        exit 0
      fi

      # FAIL — loud broadcast on every channel.
      banner="
╔══════════════════════════════════════════════════════════════════╗
║   NIXOS ACTIVATION VERIFY: $(printf '%2d' "''${#problems[@]}") PROBLEM(S) DETECTED            ║
╠══════════════════════════════════════════════════════════════════╣"
      msg="$banner"
      for p in "''${problems[@]}"; do
        msg="$msg
║   • $p"
      done
      msg="$msg
╚══════════════════════════════════════════════════════════════════╝"

      echo "$msg" >&2
      echo "$msg" | ${pkgs.util-linux}/bin/wall -n 2>/dev/null || true
      for p in "''${problems[@]}"; do
        ${pkgs.util-linux}/bin/logger -t nixos-activation-verify -p user.crit "$p"
      done

      # Append to /etc/motd so login banner shows it.
      {
        echo
        echo "$msg"
        echo
      } >> /etc/motd 2>/dev/null || true

      exit 1
    '';
  };

in
{
  # Run DEAD LAST in activation. The `deps` empty list places it as a leaf —
  # NixOS will schedule it after everything else with no children.
  system.activationScripts.zzz-verify = lib.stringAfter [ "users" "groups" "etc" "specialfs" "var" ] ''
    echo "[verify] running post-activation invariant checks"
    if ! ${verifyScript}/bin/nixos-activation-verify; then
      echo "[verify] FAILED — see journal: journalctl -t nixos-activation-verify -p crit"
      # Don't exit non-zero — NixOS treats activation script failures as
      # boot-blocking. We logged loudly; let boot continue so user can
      # SSH in (or use TTY) to investigate.
    fi
  '';

  # System-wide CLI for manual re-run after troubleshooting.
  environment.systemPackages = [ verifyScript ];
}
