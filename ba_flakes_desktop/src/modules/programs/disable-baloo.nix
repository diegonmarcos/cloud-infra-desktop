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
  # balooctl CANNOT persist the flag: HM links baloofilerc to a read-only store
  # path, so balooctl's write fails (silently, below). Its one real effect is
  # stopping the *running* daemon so the change lands without a re-login.
  # Keep this in sync with plasma.nix — this hook cannot override it.
  home.activation.disableBaloo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v balooctl6 >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl6 disable 2>/dev/null || true
    elif command -v balooctl >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl disable 2>/dev/null || true
    fi
  '';
}
