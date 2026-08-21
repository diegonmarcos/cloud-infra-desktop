# session-default-config.nix — ONE owner for what the session looks like and
# how it comes back: panels, their widgets, the tray, desktop icons, the
# wallpaper, and the login/restore policy.
#
# These were spread across plasma.nix's import list (four separate modules) and
# its own body, so "why does my session look like this" had five answers. It has
# one now: this file, and the JSON beside it. plasma.nix imports this and keeps
# only the things that are about Plasma-the-application rather than the session
# — shortcuts, kwin rules, theming, per-app settings.
#
# ── The two session cases ───────────────────────────────────────────────────
# They are different things and only one of them needs code:
#
#   1. FRESH SESSION — ksmserver starts, the autostart fires, and
#      default-session-launcher.sh imposes the template from
#      default-session.json. loginMode is emptySession so Plasma's restore does
#      not also run and give you both sets of windows.
#
#   2. RESUME FROM SNAPSHOT — the session comes back from the hibernation
#      image. ksmserver never restarts, so the autostart never fires and there
#      is nothing to decide. Correct by construction, no code.
#
# ── History, because this was nearly deleted twice ──────────────────────────
# The launcher duplicated the session on every start, and a previous version of
# this header concluded it should be dropped in favour of Plasma's own restore.
# That diagnosis was half right. The duplication was real; the cause was not the
# launcher but its gate.
#
# `run_on: fresh_only` tested `noresume` on /proc/cmdline — a per-BOOT signal
# answering a per-SESSION question, and worse, it tested which rEFInd entry was
# booted rather than what the kernel did. Verified 2026-08-21: cmdline carried
# resume=, the kernel loaded ZERO hibernation images, session start 11:31:21
# matched boot 11:31:30. A genuinely fresh session, skipped. The "rare
# cold-fall-through" the JSON dismissed is every Primary boot that did not
# hibernate. Meanwhile, within one boot the cmdline never changes, so every
# re-login and every ksmserver restart passed the gate and launched a full set —
# 13 Dolphin windows, 12 Konsole processes, 15 Brave processes, and on an 8GB
# box with a 5.6GiB user slice an OOM loop: a kill restarts the session manager,
# which fires the launcher, which adds another set.
#
# From ~/.local/state/default-session.log: the gate was never the only guard.
# An flock had blocked 86 duplicate runs against 129 that got through, and the
# last login before this rewrite fired the launcher 28 times inside one second.
# A lock is a race mitigation, not a design — it was doing the duplication
# guard's job by accident.
#
# So the gate is gone rather than fixed. Case 2 proves it could only ever
# produce false negatives. The guard is now emptiness: apply the layout only
# when none of its apps are already running — the question every proxy was
# trying to answer, idempotent by construction, and immune to however many
# times the autostart fires.
{ config, lib, pkgs, ... }:
let
  wallpaperJson = builtins.fromJSON (builtins.readFile ./cloud-data-wallpaper.json);
  wallpaperPath = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/"
    + "${wallpaperJson.wallpaper.theme}/contents/images/${wallpaperJson.wallpaper.image}";
in
{
  imports = [
    ./top-panel.nix       # top panel: storage, mem, cpu, network │ clock │ guard, psi
    ./bottom-panel.nix    # bottom panel: kickoff, pager, tasks, sysmon, TWO trays
    ./default-session.nix # the fixed default layout + its autostart entry
  ];

  # ── Login/restore policy ────────────────────────────────────────────────────
  # The fixed layout and Plasma's restore are alternatives, not partners:
  # restoring the previous session AND imposing the template gives you both sets
  # of windows. The launcher is wired, so this is emptySession and the launcher
  # populates the desktops.
  #
  # The two cases, and why only one of them needs any code:
  #   fresh session       ksmserver starts -> autostart fires -> template applied
  #   resume from image   the session comes back from RAM; ksmserver never
  #                       restarts, the autostart never fires, nothing to decide.
  #                       Correct by construction — which is why the launcher's
  #                       old boot-type gate could only ever be a false negative.
  #
  # If this is ever flipped to Plasma's own restore, the value is
  # "restorePreviousLogout" — NOT the "restorePreviousSession" that
  # ./session-restore.nix documents, which does not exist. Plasma 6.7.2's
  # ksmserver knows only restorePreviousLogout and restoreSavedSession, and an
  # unrecognised value falls through to an empty session silently.
  programs.plasma.configFile.ksmserverrc.General.loginMode = "emptySession";

  # The wallpaper stays declared in plasma.nix (programs.plasma.workspace.wallpaper,
  # plus the lock screen and SDDM, all resolved from cloud-data-wallpaper.json) —
  # it is one image used by three surfaces, only one of which is the session, and
  # a second definition of the same option is an eval conflict rather than an
  # override. Exported here so anything that needs the resolved store path reads
  # the same value instead of rebuilding it.
  home.sessionVariables.SESSION_WALLPAPER = wallpaperPath;

  # com.diegonmarcos.watchdog reads the tray daemon's snapshot with
  # XMLHttpRequest GET on file:///run/user/<uid>/my-konsole-watchdog.json. Qt 6
  # refuses local-file XHR unless this is set, and it refuses it SILENTLY as far
  # as QML is concerned — readyState reaches DONE with an empty responseText, so
  # every widget parsed nothing and drew nothing while plasmashell's journal
  # repeated "Set QML_XHR_ALLOW_FILE_READ to 1 to enable this feature."
  # It has to be in the session environment: plasmashell is started by the
  # session, so setting it any later is too late for the shell already running.
  home.sessionVariables.QML_XHR_ALLOW_FILE_READ = "1";
}
