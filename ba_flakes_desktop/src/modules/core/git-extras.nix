# core/git-extras.nix — git CLI add-ons
# Phase 1  : git-lfs + diff-so-fancy + delta             (from profile-3)
# Phase 1a : + git-filter-repo + gh                      (from profile-1)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    git-lfs
    diff-so-fancy
    delta            # better git diff
    git-filter-repo  # git history rewriting (purge secrets from commits)
    gh               # GitHub CLI
  ];
}
