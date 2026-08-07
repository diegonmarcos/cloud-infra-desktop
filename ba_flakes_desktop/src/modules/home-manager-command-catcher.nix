# home-manager-command-catcher — the missing half of the nix entrypoint net.
#
# WHY: aa_desk-usr_.../configuration_nix-command-catcher.nix already forces
# every heavy `nix` / `nixos-rebuild` through nix-switch-progress-wrap, so a
# build always runs idle-classed with a visible progress window instead of
# silently starving the session on this 8-core/8GB box. `home-manager switch`
# is every bit as heavy as `nixos-rebuild switch` and was never caught at all.
#
# It cannot be caught from the system side. `home-manager` resolves to
# ~/.nix-profile/bin/home-manager, and .nix-profile/bin sits at PATH position
# 11 while /run/current-system/sw/bin sits at 19 — a system-level wrapper
# loses the lookup every time, no matter its nix-level priority. The wrapper
# has to be installed into the *same* profile, which means from here.
#
# Two packages then provide bin/home-manager: the one programs.home-manager
# installs, and this wrapper. That is a real home-manager-path collision --
# the same class of failure that broke every desktop closure build when
# my-ai-latest and claude.nix both started shipping bin/claude-termux. The
# difference is priority: a collision is only fatal when both sides are
# EQUAL. lib.hiPrio makes this wrapper strictly preferred, which is exactly
# how curl-wget-wrapper.nix already shadows nixpkgs' curl and wget in this
# same flake, and how the system catcher shadows nix.
#
# The heavy-verb allowlist (home-manager-command-catcher.json) is deployed
# via xdg.configFile and read at RUNTIME by the script with jq — nothing is
# Nix-interpolated into the shell script itself. The one exception is the
# real binary's store path: writeShellApplication has no env facility of
# its own, so it is passed in via runtimeEnv (HM_REAL), which this nixpkgs
# supports (pkgs/build-support/trivial-builders/default.nix). The script
# file (home-manager-command-catcher.sh) stays entirely free of baked-in
# Nix values as a result.
{ config, pkgs, lib, ... }:

let
  catcher = pkgs.writeShellApplication {
    name = "home-manager";
    runtimeInputs = [ pkgs.jq ];
    runtimeEnv = {
      HM_REAL = "${pkgs.home-manager}/bin/home-manager";
    };
    text = builtins.readFile ./home-manager-command-catcher.sh;
  };
in {
  xdg.configFile."cloud-data/home-manager-command-catcher.json".source =
    ./home-manager-command-catcher.json;

  home.packages = [ (lib.hiPrio catcher) ];
}
