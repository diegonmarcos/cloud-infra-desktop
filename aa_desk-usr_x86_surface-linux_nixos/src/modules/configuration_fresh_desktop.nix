# Fresh-Desktop boot specialisation (2026-06-12).
#
# WHY THIS EXISTS
# ───────────────
# The default rEFInd entry (NixOS - Primary) auto-resumes the hibernate
# image when one exists — that's the "continue my session from disk" path.
# This specialisation is the OTHER choice at the boot menu: a FULL Plasma
# desktop that deliberately ignores any saved session (`noresume`) and
# safely invalidates the stale image (swapfile-header rewrite) so the
# next Primary boot can't resume state that predates this session's
# disk writes (2026-05-15 corruption class).
#
# Unlike the rescue-* specialisations (text-mode recovery), this is the
# everyday "start clean anyway" option: same desktop, same modules, just
# no session resume.
#
# Appears in rEFInd as "NixOS - Fresh Desktop" (boot.json manual_stanzas).
{ config, pkgs, lib, ... }:

{
  specialisation.fresh-desktop.configuration = {
    # Invalidate any pending hibernate image (gated on noresume inside the
    # module — can never act on a resume-capable boot).
    imports = [ ./configuration_rescue_invalidate_hibernate.nix ];

    # Never resume; the saved image is stale by definition once we boot.
    # boot.json: kernel.specialisations.fresh-desktop
    boot.kernelParams = lib.mkForce [
      "noresume"
      "mem_sleep_default=deep"
      "psi=1"
      "splash"
      "loglevel=4"
      "audit=1"
    ];
    boot.resumeDevice = lib.mkForce "";

    # Keep the swapfile OUT of swap this boot: the invalidator needs it
    # inactive to rewrite the header, and a fresh session shouldn't write
    # over the area until the stale image is cleared. zram still provides
    # swap. Hibernate from a fresh-desktop session: reboot into Primary
    # first (its cmdline carries resume=).
    swapDevices = lib.mkForce [ ];
  };
}
