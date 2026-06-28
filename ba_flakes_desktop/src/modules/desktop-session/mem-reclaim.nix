# mem-reclaim — data-driven memory panic button (user-level, no sudo).
#
# Installs ~/.local/bin/mem-reclaim (the engine) + ~/.config/mem-reclaim/
# essentials.json (the allowlist). `mem-reclaim` SIGTERMs/SIGKILLs every
# user process whose cmdline isn't in the allowlist, sparing the active login
# session (terminal + Claude + MCP), and records the kill set to
# $XDG_RUNTIME_DIR for `mem-reclaim restore`. Source of truth is the .sh +
# .json beside this module (same files are runnable straight from the repo).
{ config, pkgs, lib, ... }:

{
  home.file.".config/mem-reclaim/essentials.json".source = ./mem-reclaim-essentials.json;

  home.file.".local/bin/mem-reclaim" = {
    source = ./mem-reclaim.sh;
    executable = true;
  };
}
