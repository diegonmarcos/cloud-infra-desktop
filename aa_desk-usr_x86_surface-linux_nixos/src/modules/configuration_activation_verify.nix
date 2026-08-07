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
  # Required human users and required paths are DATA, not Nix-eval-time
  # config: they live in activation-verify.json, deployed to
  # /etc/cloud-data/activation-verify.json (a NEW path — no existing module
  # declares it) and read at RUNTIME via jq. See nixos-activation-verify.sh
  # for the full check logic (inline shell in nix modules is forbidden).
  verifyScript = pkgs.writeShellApplication {
    name = "nixos-activation-verify";
    runtimeInputs = with pkgs; [ coreutils gawk util-linux gnugrep jq ];
    text = builtins.readFile ./nixos-activation-verify.sh;
  };

in
{
  environment.etc."cloud-data/activation-verify.json".source = ./activation-verify.json;

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
