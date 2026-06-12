# Rescue-path hibernate-image invalidation (POST-INCIDENT 2026-05-15, REWRITTEN 2026-06-12).
#
# WHY THIS EXISTS
# ───────────────
# When NixOS boots via a rescue specialisation (`rescue-current-gen` or
# `rescue-native-install`), the kernel cmdline strips `resume=*` and adds
# `noresume` — so the kernel won't resume from any hibernate image on the
# swap device. Good.
#
# BUT: the image is still on disk. If the next normal boot DOES carry
# `resume=...`, the kernel will happily resume from that stale image, even
# though the rescue boot may have written to the pool in the meantime.
# That's the 2026-05-15 failure mode.
#
# Fix: on every rescue (noresume) boot, rewrite the SWAPFILE's header so any
# hibernate signature is gone. The next boot — rescue or normal — finds a
# clean SWAPSPACE2 and cold-boots. No silent resume from a stale image.
#
# ⚠ 2026-06-12 INCIDENT — WHY THIS MODULE WAS REWRITTEN ⚠
# ─────────────────────────────────────────────────────────
# The previous version dd-zeroed + mkswap'ed the RESUME DEVICE
# (/dev/disk/by-label/Shared-Lib). That device is NOT a swap partition — it
# is the ext4 filesystem CONTAINING the swapfile (`resume=` names the
# backing device, `resume_offset=` locates the file's first extent within
# it). Writing its first 4 KiB destroyed the ext4 primary superblock: the
# fslabel vanished, /mnt/shared-lib became unmountable, the swapfile was
# unreachable, and the battery watchdog's hibernate calls all failed with
# "Not enough suitable swap space" until the battery drained dead.
# Recovered via `fsck.ext4 -b 32768` (backup superblock).
# It was also WantedBy=sysinit.target with no condition, so it ran on every
# NORMAL boot too — not just rescue boots.
#
# CORRECT INVALIDATION (this version — matches boot.json
# swap_hibernate.hibernate_invalidation.method):
#   - Target the SWAPFILE PATH through the mounted filesystem. The swap
#     header (and any S1SUSPEND signature) lives in the first page OF THE
#     FILE. `mkswap <file>` rewrites it in place; ext4 extents are fixed,
#     so the file does not move and resume_offset stays valid.
#   - ConditionKernelCommandLine=noresume — hard guarantee this NEVER acts
#     on a normal boot, even if wired into the wrong config.
#   - RequiresMountsFor orders us after the Shared-Lib mount; no
#     DefaultDependencies surgery, no ordering cycles (the old unit put
#     DefaultDependencies in [Service] where systemd ignores it, producing
#     sysinit.target/local-fs.target ordering cycles every boot).
#   - If the swapfile is already ACTIVE swap, skip: util-linux swapon has
#     already rewritten any software-suspend signature at activation.
#
# Imported by the rescue specialisations only (configuration_rescue.nix and
# configuration_rescue_native-install.nix), per boot.json
# swap_hibernate.hibernate_invalidation.trigger_specialisations.
{ config, pkgs, lib, ... }:

let
  bootCfg  = builtins.fromJSON (builtins.readFile ./boot.json);
  swapfile = bootCfg.swap_hibernate.swapfile;
in
{
  systemd.services."rescue-invalidate-hibernate" = {
    description = "Invalidate any stale hibernate signature in the swapfile (rescue/noresume boots only)";
    wantedBy    = [ "multi-user.target" ];
    unitConfig = {
      # Only ever act on a boot that explicitly refuses to resume.
      ConditionKernelCommandLine = "noresume";
      # Pulls in + orders after the mount unit for the filesystem holding
      # the swapfile. If the mount fails, we simply don't run.
      RequiresMountsFor = swapfile;
    };
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils util-linux ];
    script = ''
      SWAP=${lib.escapeShellArg swapfile}

      if [ ! -f "$SWAP" ]; then
        logger -t rescue-invalidate-hibernate -p user.warning \
          "swapfile $SWAP not present — nothing to invalidate"
        exit 0
      fi

      # Active swap: swapon already rewrote any S1SUSPEND signature when it
      # activated the area, and mkswap would (rightly) refuse anyway.
      if awk -v f="$SWAP" '$1 == f { found=1 } END { exit !found }' /proc/swaps; then
        logger -t rescue-invalidate-hibernate -p user.info \
          "swapfile $SWAP is active swap — signature already clean, skipping"
        exit 0
      fi

      # Header magic sits at byte 4086 of the swap area's first page:
      # "SWAPSPACE2" = clean swap, "S1SUSPEND " = pending hibernate image.
      MAGIC=$(dd if="$SWAP" bs=1 skip=4086 count=10 status=none | tr -d '\0')
      logger -t rescue-invalidate-hibernate -p user.info \
        "swapfile $SWAP header magic before invalidation: '$MAGIC'"

      # Rewrite the swap header INSIDE THE FILE. Never touch the partition:
      # the backing device is the ext4 filesystem itself (2026-06-12 incident).
      mkswap "$SWAP" >/dev/null

      logger -t rescue-invalidate-hibernate -p user.warning \
        "rescue boot: swap header of $SWAP rewritten (was: '$MAGIC', now: SWAPSPACE2). No stale resume possible."
    '';
  };
}
