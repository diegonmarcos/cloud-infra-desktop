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
# ── Why the default-session launcher is gone ────────────────────────────────
# default-session-launcher.sh built the layout by hand: spawn ten apps, drive
# Konsole's DBus to build tab/split trees, then re-assert window geometry across
# ten KWin scripting passes. The .sh and .json stay in this folder for reference
# (the Konsole tab-building technique is genuinely hard-won); default-session.nix
# — the module that deployed them and installed the autostart entry — is gone,
# so there is nothing left to re-wire it by accident.
#
# It was removed because it duplicated the session on every start.
# `run_on: fresh_only` tests for `noresume` on /proc/cmdline — a per-BOOT
# signal, while the autostart fires per SESSION START. Within one boot the
# cmdline never changes, so every re-login and every ksmserver restart passed
# the gate and launched a complete fresh set. That is where the 13 Dolphin
# windows, 12 Konsole processes and 15 Brave processes came from, and on an 8GB
# box with a 5.6GiB user slice it fed an OOM loop: a kill restarts the session
# manager, the session manager fires the launcher, the launcher adds another
# full set, and round it goes.
#
# 2026-08-21, from ~/.local/state/default-session.log, correcting this note:
# the gate was NOT the only guard — the launcher also takes an flock, and that
# lock had blocked 86 duplicate runs against 129 that got through. The lock is
# what kept this from being worse. It was also still firing right up to the
# removal: 28 invocations in ONE second on the last login, all landing on the
# skip path only because that was a restore boot (resume= on cmdline). On a
# fresh boot all 28 would have passed the gate, leaving a single flock as the
# only thing between the box and 28 concurrent layout builds.
#
# The lesson is in the shape, not the counts: a per-boot gate cannot guard a
# per-session event, and a lock is a race mitigation, not a design.
#
# Plasma's own session restore does the same job without any of that. It
# reopens what was actually open, on the right desktops, at the right sizes,
# via each app's own state restoration — no window-class guessing, no geometry
# re-assertion, and structurally no way to fire twice. What it does not do is
# impose a fixed template; it gives you your last session instead. That is the
# trade, and it is the right one here: a template that reliably duplicates
# itself is worth less than a restore that doesn't.
{ config, lib, pkgs, ... }:
let
  wallpaperJson = builtins.fromJSON (builtins.readFile ./cloud-data-wallpaper.json);
  wallpaperPath = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/"
    + "${wallpaperJson.wallpaper.theme}/contents/images/${wallpaperJson.wallpaper.image}";

  # Same convention as plasma.nix's repair scripts: the shell lives in a .sh,
  # nothing is Nix-interpolated into it, and the module just calls the result.
  defaultSessionReapScript = pkgs.writeShellApplication {
    name = "default-session-reap";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./default-session-reap.sh;
  };
in
{
  imports = [
    ./top-panel.nix       # top panel: storage, mem, cpu, network │ clock │ guard, psi
    ./bottom-panel.nix    # bottom panel: kickoff, pager, tasks, sysmon, TWO trays
  ];

  # ── Login/restore policy ────────────────────────────────────────────────────
  # The fixed layout and Plasma's restore are alternatives, not partners:
  # restoring the previous session AND imposing the template gives you both sets
  # of windows. With the launcher unwired, this flips back to Plasma's restore.
  #
  # "restorePreviousLogout", NOT "restorePreviousSession" — the latter is the
  # value ./session-restore.nix documents and it does not exist. Plasma 6.7.2's
  # ksmserver only knows restorePreviousLogout and restoreSavedSession; anything
  # else falls through to an empty session, so the typo would have SILENTLY
  # given us exactly the emptySession we are trying to leave.
  programs.plasma.configFile.ksmserverrc.General.loginMode = "restorePreviousLogout";

  # ── Reap the launcher's deployed artifacts ──────────────────────────────────
  # Deleting default-session.nix does not remove what it already wrote to disk,
  # and ~/.config/autostart is read by ksmserver rather than home-manager, so an
  # orphaned .desktop would keep firing the launcher on every login. The reasons
  # and the safety argument live in the script's header, not here.
  home.activation.reapDefaultSessionLauncher = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${defaultSessionReapScript}/bin/default-session-reap || true
  '';

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
