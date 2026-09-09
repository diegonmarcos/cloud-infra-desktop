# The Android application id is the single value every on-device path derives
# from, and this module is where it is applied to the two places the upstream
# nix-on-droid input hardcodes.
#
# WHY THIS FILE EXISTS
#
# The phone runs two Nix-on-Droid terminals side by side: com.termux.nix (the
# official F-Droid app) and cld.termux.nix (our fork, renamed 2026-08-30 in
# cloud-u-android/ac_cloud-nix-on-droid precisely so it installs ALONGSIDE the
# official one instead of colliding with it). Android gives each its own private
# data directory, so every path this flake writes is namespaced by whichever id
# the activation is running inside.
#
# Upstream pins both halves of that namespace to a com.termux.nix literal:
#
#   modules/user.nix          user.home             = /data/data/com.termux.nix/files/home
#   modules/build/config.nix  build.installationDir = /data/data/com.termux.nix/files/usr
#
# home.homeDirectory follows user.home, and Home Manager's activation calls
# checkHomeDirectory, which exits 1 with 'HOME is set to X but we expect Y' when
# the two disagree. So a switch run inside cld.termux.nix aborted before
# linkGeneration ever ran, and that app ended up with NO configuration at all --
# no ~/.termux/termux.properties, therefore allow-external-apps unset, therefore
# RunCommandService refusing the boot companion's intent and nothing starting at
# boot. That is the failure this module fixes.
#
# installationDir matters just as much, and worse: it is what the generated
# /bin/login is built from, /bin inside the proot IS <id>/files/usr/bin, and the
# nix-on-droid activation rewrites /bin/login every generation. Left pointing at
# the other app, activating inside the renamed terminal would replace its login
# script with one that execs a proot-static it cannot even read -- bricking the
# terminal instead of configuring it.
#
# BOTH options are declared `readOnly`, which the module system refuses to let a
# second definition touch at all -- mkForce does not help, the check is on the
# number of definitions, not their priority (CI run 34373168936: "The option
# `user.home' is read-only, but it's set multiple times"). Disabling the two
# upstream modules and re-declaring their option groups is the only way to move
# them. The disabledModules entries live in flake.nix, where the nix-on-droid
# path is an ordinary let-binding -- referring to a module argument from
# disabledModules is what makes the module system recurse infinitely.
#
# Everything below except the two derived DEFINITIONS is a verbatim copy of
# upstream's modules/user.nix and modules/build/config.nix. Keep it in step when
# the nix-on-droid pin moves; a diff of those two files is the whole review.
{ config, lib, pkgs, androidPackage, ... }:

with lib;

let
  cfg = config.user;

  idsDerivation = pkgs.runCommandLocal "ids.nix" { } ''
    cat > $out <<EOF
    {
      gid = $(${pkgs.coreutils}/bin/id -g);
      uid = $(${pkgs.coreutils}/bin/id -u);
    }
    EOF
  '';

  ids = import idsDerivation;
in

{
  options = {

    user = {
      group = mkOption {
        type = types.str;
        default = "nix-on-droid";
        description = "Group name.";
      };

      gid = mkOption {
        type = types.int;
        default = ids.gid;
        defaultText = "$(id -g)";
        description = ''
          Gid.  This value should not be set manually except you know what you are doing.
        '';
      };

      home = mkOption {
        type = types.path;
        readOnly = true;
        description = "Path to home directory.";
      };

      shell = mkOption {
        type = types.path;
        default = "${pkgs.bashInteractive}/bin/bash";
        defaultText = literalExpression "${pkgs.bashInteractive}/bin/bash";
        description = "Path to login shell.";
      };

      userName = mkOption {
        type = types.str;
        default = "nix-on-droid";
        description = "User name.";
      };

      uid = mkOption {
        type = types.int;
        default = ids.uid;
        defaultText = "$(id -u)";
        description = ''
          Uid.  This value should not be set manually except you know what you are doing.
        '';
      };
    };

    build = {
      initialBuild = mkOption {
        type = types.bool;
        default = false;
        internal = true;
        description = ''
          Whether this is the initial build for the bootstrap zip ball.
          Should not be enabled manually, see
          <filename>initial-build.nix</filename>.
        '';
      };

      installationDir = mkOption {
        type = types.path;
        internal = true;
        readOnly = true;
        description = "Path to installation directory.";
      };

      extraProotOptions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra options passed to proot, e.g., extra bind mounts.";
      };
    };

  };

  config = {

    environment.etc = {
      "group".text = ''
        root:x:0:
        ${cfg.group}:x:${toString cfg.gid}:${cfg.userName}
      '';

      "passwd".text = ''
        root:x:0:0:System administrator:${config.build.installationDir}/root:/bin/sh
        ${cfg.userName}:x:${toString cfg.uid}:${toString cfg.gid}:${cfg.userName}:${cfg.home}:${cfg.shell}
      '';
    };

    # The only two lines in this file that are not upstream's.
    user.home = "/data/data/${androidPackage}/files/home";
    build.installationDir = "/data/data/${androidPackage}/files/usr";

  };
}
