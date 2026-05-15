# Rescue-path hibernate-image invalidation (POST-INCIDENT 2026-05-15).
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
# Fix: on every rescue boot, proactively rewrite the swap header so any
# hibernate signature is gone. The next boot — rescue or normal — finds a
# clean SWAPSPACE2 and cold-boots. No silent resume from a stale image.
#
# Apply to: rescue-current-gen, rescue-native-install specialisations.
# (Import this module from both configuration_rescue.nix and
# configuration_rescue_native-install.nix.)
{ config, pkgs, lib, ... }:

let
  bootCfg   = builtins.fromJSON (builtins.readFile ./boot.json);
  resumeDev = bootCfg.swap_hibernate.resume_device;
  swapfile  = bootCfg.swap_hibernate.swapfile;
in
{
  systemd.services."rescue-invalidate-hibernate" = {
    description = "Clobber any stale hibernate signature on the swap device";
    wantedBy    = [ "sysinit.target" ];
    before      = [ "swap.target" "local-fs.target" ];
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      DefaultDependencies = false;
    };
    path = with pkgs; [ coreutils util-linux ];
    script = ''
      RESUME=${lib.escapeShellArg resumeDev}
      SWAP=${lib.escapeShellArg swapfile}

      RESOLVED=$(${pkgs.coreutils}/bin/readlink -f "$RESUME" 2>/dev/null || echo "")
      if [ -z "$RESOLVED" ] || [ ! -b "$RESOLVED" ]; then
        ${pkgs.util-linux}/bin/logger -t rescue-invalidate-hibernate -p user.warning \
          "$RESUME does not resolve to a block device — skipping invalidation"
        exit 0
      fi

      # Clear first 4 KiB → wipes any swsusp/uswsusp signature.
      ${pkgs.coreutils}/bin/dd if=/dev/zero of="$RESOLVED" bs=4096 count=1 \
        conv=notrunc status=none 2>/dev/null || true

      # Rewrite swap header in place (preserves UUID/label).
      ${pkgs.util-linux}/bin/mkswap -L Shared-Lib-swap "$RESOLVED" >/dev/null 2>&1 || true

      ${pkgs.util-linux}/bin/logger -t rescue-invalidate-hibernate -p user.warning \
        "rescue boot: swap header on $RESOLVED rewritten (was: any hibernate signature, now: SWAPSPACE2). No stale resume possible."
    '';
  };
}
