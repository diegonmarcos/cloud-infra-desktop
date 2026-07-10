# programs/disable-baloo.nix — disable the KDE file indexer (baloo).
# 2026-07-10: baloo (baloo_file + baloo_file_ext) spun to ~50% CPU re-indexing
# after heavy file churn, contributing to a CPU-pressure freeze on this 8GB box.
# baloo is a well-known CPU/IO hog with little value on a dev machine that
# searches via ripgrep/fd. Disabled declaratively (baloofilerc) + a live
# `balooctl disable` on activation so it takes effect without a re-login.
{ config, pkgs, lib, ... }:
{
  # Authoritative: baloofilerc with indexing off. plasma-manager may also touch
  # this; a plain home.file is the single writer for the Basic Settings block.
  home.file.".config/baloofilerc".text = ''
    [Basic Settings]
    Indexing-Enabled=false
  '';

  # Stop + purge the running indexer at activation (no re-login needed). Uses
  # balooctl6 (Plasma 6); best-effort, never fails the switch.
  home.activation.disableBaloo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v balooctl6 >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl6 disable 2>/dev/null || true
    elif command -v balooctl >/dev/null 2>&1; then
      $DRY_RUN_CMD balooctl disable 2>/dev/null || true
    fi
  '';
}
