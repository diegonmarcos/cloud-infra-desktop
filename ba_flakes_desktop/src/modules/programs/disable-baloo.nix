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
  # Instead disable + purge the indexer at activation with balooctl, which
  # persists Indexing-Enabled=false into baloofilerc itself. Runs after the
  # plasma config is written, so it wins; re-applied on every switch.
  home.activation.disableBaloo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v balooctl6 >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl6 disable 2>/dev/null || true
    elif command -v balooctl >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl disable 2>/dev/null || true
    fi
  '';
}
