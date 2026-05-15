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
{
  systemd.services."pool-witness-stamp-on-mount" = {
    description = "Stamp a fresh nonce on the pool to detect out-of-band mounts";
    wantedBy    = [ "local-fs.target" ];
    after       = [ "mnt-shared.mount" "local-fs.target" ];
    before      = [ "systemd-hibernate.service" "sleep.target" ];
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      Slice          = "os-essentials.slice";
    };
    path = with pkgs; [ coreutils util-linux ];
    script = ''
      set -eu
      mkdir -p /mnt/shared/.pool-witness /run/pool-witness /var/lib/pool-witness

      # Boot-time check: previous nonce on disk must match what we last wrote
      # at clean shutdown. If mismatched, something else mounted the pool —
      # log loudly so the hibernate preflight gate can refuse.
      PREV=$(cat /mnt/shared/.pool-witness/id 2>/dev/null || echo "")
      LAST=$(cat /var/lib/pool-witness/last-clean-mount.id 2>/dev/null || echo "")
      if [ -n "$LAST" ] && [ -n "$PREV" ] && [ "$PREV" != "$LAST" ]; then
        ${pkgs.util-linux}/bin/logger -t pool-witness -p user.crit \
          "POOL MOUNTED OUT-OF-BAND: disk_nonce=$PREV expected=$LAST — hibernate will be refused this boot. Source: another OS or live-USB unlocked LUKS and mounted the pool."
      fi

      # Stamp this boot.
      NEW=$(${pkgs.coreutils}/bin/head -c16 /dev/urandom \
            | ${pkgs.coreutils}/bin/od -An -tx1 | tr -d ' \n')
      echo "$NEW" > /mnt/shared/.pool-witness/id
      echo "$NEW" > /run/pool-witness/current-mount.id
      ${pkgs.coreutils}/bin/sync -f /mnt/shared/.pool-witness/id

      ${pkgs.util-linux}/bin/logger -t pool-witness -p user.info \
        "stamped nonce=$NEW for this NixOS boot"
    '';
  };

  systemd.services."pool-witness-commit-on-shutdown" = {
    description = "Promote runtime nonce to last-clean-mount on graceful shutdown";
    wantedBy    = [ "shutdown.target" ];
    before      = [ "umount.target" "shutdown.target" ];
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      DefaultDependencies = false;
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
