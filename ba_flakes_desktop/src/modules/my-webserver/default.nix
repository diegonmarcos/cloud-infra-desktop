# my-webserver — file server with Markdown, JSON/YAML table and Eruda DevTools.
# Provides: the `my-webserver` command (start|stop|status|restart) and the
# desktop entry. The BINARY and the SERVICE come from the app's own flake.
#
# What used to be here: a fetchurl derivation, its own hashes.json, and ~60
# lines of hard-won patchelf lore (a newer patchelf than stdenv's, which
# SIGABRTs on this binary's PT_INTERP; dontStrip, because stripping corrupts
# the Node SEA blob sections). All of it correct, all of it also living in
# bb_flakes_termux, with vm-pilot describing the unit a third time — four
# places that had to agree about one artifact and nothing making them.
#
# It now lives once, in da__shared/lib/prebuilt.nix, which every app inherits.
# Verified after the move: the binary boots Node 22.23.2 and runs the embedded
# SEA. Both mistakes were re-made during that move and both dumped core, which
# is how thoroughly that knowledge needed a single home.
{ config, pkgs, lib, inputs, ... }:

let
  httpdBin = "${inputs.my-webserver.packages.${pkgs.stdenv.hostPlatform.system}.my-webserver-bin}/bin/my-webserver";

  # Shell body lives in ./my-webserver.sh. The only value Nix ever interpolated
  # into it was the fetched binary's store path, passed via runtimeEnv rather
  # than baked into the script text.
  httpdWrapperScript = pkgs.writeShellApplication {
    name = "my-webserver";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      HTTPD_WEB_SERVER_BIN = httpdBin;
      # Deliberately NOT setting HTTPD_WRITE here. The write API
      # (/__api__/write, /__api__/git) exists for the termux device, where the
      # editing tools run against the always-on :8000 instance. Nothing on
      # desktop uses it, and an enabled-but-unused write path is just surface.
      # To turn it on later: set HTTPD_WRITE=1, HTTPD_WRITE_ROOTS to the
      # directories it may touch, and HTTPD_WRITE_TOKEN_FILE to a rendered
      # secret — see bb_flakes_termux's module for the full wiring. The server
      # fails closed without all three.
    };
    text = builtins.readFile ./my-webserver.sh;
  };
in
{
  # The service itself — one description, shared with every other consumer and
  # with the tarball a machine without nix installs. It also brings the
  # resource limits this unit never had: Nice, IOSchedulingClass, MemoryMax and
  # the MemorySwapMax=0 without which a capped leak is pushed into swap
  # instead of being killed.
  imports = [ inputs.my-webserver.homeManagerModules.default ];

  services.my-webserver = {
    enable = true;
    # %h is a systemd specifier and is correct in a unit — unlike in the
    # .desktop entry below, where the spec defines no home-directory field
    # code and desktop-file-validate rejects it.
    args = "8000 %h";
  };

  # Deploy the POSIX wrapper as my-webserver.
  home.file.".local/bin/my-webserver".source =
    "${httpdWrapperScript}/bin/my-webserver";

  xdg.desktopEntries.my-webserver = {
    name = "my-webserver";
    comment = "Local file server — Markdown + JSON/YAML tables + Eruda DevTools";
    # NOT %h. The Desktop Entry spec defines no home-directory field code, so
    # desktop-file-validate rejects it and the .desktop derivation fails the
    # build -- which takes home-manager-path and the whole generation with it.
    # Here the path has to be interpolated at eval time.
    exec = "my-webserver restart 8000 ${config.home.homeDirectory}";
    icon = "my-webserver";
    terminal = false;
    categories = [ "Network" "Utility" ];
  };
}
