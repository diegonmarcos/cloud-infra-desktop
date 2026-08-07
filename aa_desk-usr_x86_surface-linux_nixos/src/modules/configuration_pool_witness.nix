# Pool-mount witness — detects out-of-band pool mounts (POST-INCIDENT 2026-05-15).
#
# WHY THIS EXISTS
# ───────────────
# The 2026-05-15 pool corruption involved a hibernate-resume scenario where
# the pool's on-disk state diverged from the resumed kernel's in-RAM view.
# Anything that mounts the pool between NixOS's clean unmount and the next
# NixOS boot (rescue-os-debian, Kali, NixOS rescue specialisation, manual
# cryptsetup-open + mount from a live USB) advances the pool's state while
# our hibernate image (if any) still encodes the older state.
#
# This module installs a cheap nonce-based witness: every clean NixOS mount
# stamps a fresh random ID into @shared/.pool-witness/id AND mirrors it to
# /run/pool-witness/current-mount.id; clean unmount promotes the runtime
# nonce to /var/lib/pool-witness/last-clean-mount.id. On the NEXT mount, the
# on-disk nonce MUST match last-clean-mount.id — if it doesn't, something
# else wrote to the pool. The hibernate preflight gate
# (configuration_pre-hibernate-warning.nix) consults this signal and refuses
# to hibernate when the nonces diverge.
#
# This adds zero runtime overhead beyond a 16-byte write at mount/unmount.
{ config, pkgs, lib, ... }:
let
  witnessDir = "/mnt/shared/.pool-witness";

  # pool-witness-stamp-on-mount: shell body lives in
  # ./pool-witness-stamp-on-mount.sh, data-driven at runtime from
  # /etc/cloud-data/pool-witness.json (declared below).
  poolWitnessStampOnMount = pkgs.writeShellApplication {
    name = "pool-witness-stamp-on-mount";
    runtimeInputs = with pkgs; [ coreutils util-linux jq ];
    text = builtins.readFile ./pool-witness-stamp-on-mount.sh;
  };
in
{
  # Runtime data for pool-witness-stamp-on-mount (new cloud-data path —
  # verified against the already-declared environment.etc."cloud-data/..."
  # set, no collisions).
  environment.etc."cloud-data/pool-witness.json".text = builtins.toJSON {
    witness_dir = witnessDir;
  };

  # Ensure the on-pool witness directory exists (tmpfiles runs at boot).
  # /run/pool-witness and /var/lib/pool-witness are managed declaratively
  # by RuntimeDirectory= and StateDirectory= on the service units.
  systemd.tmpfiles.rules = [
    "d ${witnessDir} 0700 root root -"
  ];

  systemd.services."pool-witness-stamp-on-mount" = {
    description = "Stamp a fresh nonce on the pool to detect out-of-band mounts";
    wantedBy    = [ "local-fs.target" ];
    after       = [ "mnt-shared.mount" "local-fs.target" ];
    before      = [ "systemd-hibernate.service" "sleep.target" ];
    serviceConfig = {
      Type             = "oneshot";
      RemainAfterExit  = true;
      Slice            = "os-essentials.slice";
      # Auto-managed by systemd: /run/pool-witness (cleaned on reboot),
      # /var/lib/pool-witness (persistent across reboots — also persisted
      # via @nixos subvol since the install runs with rootfs on tmpfs).
      RuntimeDirectory = "pool-witness";
      RuntimeDirectoryMode = "0700";
      StateDirectory   = "pool-witness";
      StateDirectoryMode = "0700";
      ExecStart        = "${poolWitnessStampOnMount}/bin/pool-witness-stamp-on-mount";
    };
  };

  systemd.services."pool-witness-commit-on-shutdown" = {
    description = "Promote runtime nonce to last-clean-mount on graceful shutdown";
    wantedBy    = [ "shutdown.target" ];
    before      = [ "umount.target" "shutdown.target" ];
    serviceConfig = {
      Type                = "oneshot";
      RemainAfterExit     = true;
      DefaultDependencies = false;
      # StateDirectory already declared on the stamp service; reuse it here.
      # Required so /var/lib/pool-witness exists if this fires before the
      # stamp service ran (defensive — shouldn't happen in normal flow).
      StateDirectory      = "pool-witness";
      StateDirectoryMode  = "0700";
    };
    path = with pkgs; [ coreutils ];
    script = ''
      if [ -r /run/pool-witness/current-mount.id ]; then
        cp /run/pool-witness/current-mount.id /var/lib/pool-witness/last-clean-mount.id
        ${pkgs.coreutils}/bin/sync /var/lib/pool-witness/last-clean-mount.id
      fi
    '';
  };
}
