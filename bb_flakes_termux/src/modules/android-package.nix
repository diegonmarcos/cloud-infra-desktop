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
#   modules/user.nix        user.home           = /data/data/com.termux.nix/files/home
#   modules/build/config.nix build.installationDir = /data/data/com.termux.nix/files/usr
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
# user.home is a plain definition upstream (not mkDefault), so it needs mkForce.
# installationDir is declared readOnly, which the module system refuses to let a
# second definition touch at all; the ONLY way to move it is to disable the
# upstream module and re-declare the option group. The disabledModules entry
# lives in flake.nix, where the nix-on-droid path is an ordinary let-binding --
# referring to a module argument from disabledModules is what makes the module
# system recurse infinitely.
{ lib, androidPackage, ... }:

{
  options = {
    # Verbatim re-declaration of the upstream `build` option group that the
    # disabledModules entry in flake.nix removed. Only the installationDir
    # DEFINITION below differs from upstream; keep this block in step when the
    # nix-on-droid pin moves.
    build = {
      initialBuild = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = ''
          Whether this is the initial build for the bootstrap zip ball.
          Should not be enabled manually, see
          <filename>initial-build.nix</filename>.
        '';
      };

      installationDir = lib.mkOption {
        type = lib.types.path;
        internal = true;
        readOnly = true;
        description = "Path to installation directory.";
      };

      extraProotOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra options passed to proot, e.g., extra bind mounts.";
      };
    };
  };

  config = {
    build.installationDir = "/data/data/${androidPackage}/files/usr";
    user.home = lib.mkForce "/data/data/${androidPackage}/files/home";
  };
}
