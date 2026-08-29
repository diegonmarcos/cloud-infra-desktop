# programs/disable-baloo.nix — disable the KDE file indexer (baloo).
# 2026-07-10: baloo (baloo_file + baloo_file_ext) spun to ~50% CPU re-indexing
# after heavy file churn, contributing to a CPU-pressure freeze on this 8GB box.
# baloo is a well-known CPU/IO hog with little value on a dev machine that
# searches via ripgrep/fd. Disabled declaratively (baloofilerc) + a live
# `balooctl disable` on activation so it takes effect without a re-login.
{ config, pkgs, lib, ... }:
{
  # NB: do NOT write ~/.config/baloofilerc via home.file — plasma-manager
  # (programs.plasma) already manages that file, and two managed writers is a
  # hard HM eval error ("Conflicting managed target files: .config/baloofilerc").
  #
  # The ONLY durable switch is `Indexing-Enabled` in desktop/plasma.nix, which
  # renders baloofilerc into the store. 2026-08-11: that line said `true` while
  # this module called `balooctl6 disable`, so baloo was re-enabled on every
  # switch and OOMD killed plasmashell under the resulting memory pressure.
  #
  # balooctl can only persist the flag while HM is NOT actually owning
  # baloofilerc. That caveat is the whole problem: baloo REWRITES
  # ~/.config/baloofilerc at session start, replacing the store symlink with a
  # real file of its own defaults — the same failure kwinrulesrc, konsolerc and
  # "Profile 1.profile" all hit (see desktop/window-rules.json). Measured
  # 2026-08-29, three minutes after a fresh session: the live file was baloo's
  # stock exclude-filter list with no Indexing-Enabled key at all, while
  # plasma.nix declared it false, and baloo_file_extractor was at 63% CPU with a
  # 381MB index on a box that had 479MB MemAvailable.
  #
  # So neither writer can win a file baloo takes back on every login, and a
  # switch-time hook cannot help either — by the time it next runs, the damage
  # has already been done for that session. The only thing baloo cannot rewrite
  # is whether its unit is allowed to start at all, which is what the mask below
  # is for. Config stays declared in plasma.nix as documentation of intent and
  # for the case where baloo is deliberately re-enabled; the mask is what makes
  # "disabled" true.
  home.activation.disableBaloo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v balooctl6 >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl6 disable 2>/dev/null || true
    elif command -v balooctl >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl disable 2>/dev/null || true
    fi
  '';

  # A unit symlinked to /dev/null is masked: systemd refuses to start it, and
  # nothing baloo writes to its own config can undo that. ~/.config/systemd/user
  # is the HIGHEST-priority search path for user units, so this outranks the
  # runtime-linked kde-baloo.service that plasma-workspace drops in (it was
  # `linked-runtime` and `active` on 2026-08-29). Masking rather than disabling
  # because `disable` only clears Install symlinks, and this unit is pulled in
  # by the desktop session, not by a wants/ link.
  xdg.configFile."systemd/user/kde-baloo.service".source = "/dev/null";
}
