# Plasma session save/restore — DECLARATIVE template for default session.
#
# DESIGN (replaces session-template.{nix,json} from 2026-04-30):
#   The JSON-template + autostart approach was abandoned because:
#     - Plasma 6's kstart no longer accepts --desktop / --geometry / --title
#     - konsole's --title is silently overwritten by the shell
#     - Multi-instance kwin rules can't disambiguate without unique titles
#     - Per-desktop pinning needs UUID lookup (fragile)
#
#   This module uses Plasma's NATIVE session manager — the same mechanism
#   System Settings → Startup → Session Restoration uses. Plasma owns
#   the matching (no WM_CLASS guessing); apps state-restore via DBus.
#
# WORKFLOW (3 stages):
#
#   STAGE A — capture (one-time, requires logout+login):
#     1. This module sets loginMode = "restorePreviousSession"
#     2. User arranges perfect 4-desktop session (apps, positions, etc.)
#     3. User logs out → Plasma writes:
#          ~/.config/session/<sid>_<app>_<token>  (per-app binary state)
#          ksmserverrc [Session: ...] block       (client list)
#     4. User logs back in → verifies apps land correctly
#     5. User runs ./capture-session.sh → copies state into
#          modules/desktop/session-snapshot/
#
#   STAGE B — own (declarative, after capture):
#     6. session-snapshot/ committed to git
#     7. This module deploys snapshot files via home.file on every switch
#     8. loginMode flips to "restoreSavedSession"
#     9. Every login replays the FROZEN template
#
#   STAGE C — re-capture (when you want to update the template):
#     - Switch loginMode back to restorePreviousSession temporarily,
#       arrange new layout, log out, capture, switch back.
#
# CURRENT STATE: Stage A in progress — loginMode set to capture mode,
# but no snapshot exists yet.
#
{ config, pkgs, lib, ... }:
let
  snapshotDir = ./session-snapshot;
  snapshotExists = builtins.pathExists (snapshotDir + "/captured");
in
{
  # NOTE (2026-08-21): ksmserverrc.General.loginMode is owned by
  # ./session-default-config.nix, now set to "restorePreviousLogout".
  # ./default-session.nix — the previous owner, which set "emptySession" for the
  # data-driven launcher — has been deleted along with that launcher's wiring.
  # Defining loginMode here too would be a plasma-manager double-definition
  # error. The snapshot-deploy mechanism below is retained but inert (no
  # snapshot captured), and this module is not imported by anything.
  #
  # WARNING for anyone following the staged plan in the header above: the value
  # it names, "restorePreviousSession", DOES NOT EXIST. Plasma 6.7.2's ksmserver
  # recognises only "restorePreviousLogout" and "restoreSavedSession"; an
  # unrecognised value falls through to an empty session, silently, which is
  # indistinguishable from the restore simply not working.

  # Stage B: deploy the snapshot files into ~/.config/session/ via home.file.
  # Only fires once session-snapshot/captured exists (a marker file the
  # capture script creates after a successful capture).
  home.file = lib.optionalAttrs snapshotExists (
    let
      files = builtins.readDir snapshotDir;
      sessionFiles = lib.filterAttrs (n: t: t == "regular" && n != "captured" && n != "ksmserverrc.fragment") files;
    in
    lib.mapAttrs' (name: _: lib.nameValuePair
      ".config/session/${name}"
      { source = snapshotDir + "/${name}"; }
    ) sessionFiles
  );
}
