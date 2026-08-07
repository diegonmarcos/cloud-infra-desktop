# programs/dev-shell.nix — the USERSPACE↔DEV boundary launcher (Design B, 2026-06-19).
#
# `dev`            → interactive shell inside the dev userspace ([dev] prompt).
# `dev -- <cmd…>`  → run one command inside it (e.g. `dev -- rustc --version`).
#
# Mechanism: bubblewrap enters a mount namespace that is the FULL host
# (--dev-bind / / : HOME, Wayland/X, network, /dev) with exactly ONE change — the
# p5 dev-store (storeDir=/nix/store, physical root /mnt/shared-lib/dev-store) is
# overlaid on /nix/store, masking the pool store. So inside `dev` ONLY the heavy
# toolchain (built by bc_flakes_dev-store) resolves; outside, none of it is on
# PATH. The dev profile is self-complete (carries its own bash/coreutils — the
# pool's are masked). Boot-independent: fails closed if p5 is absent.
# Data-driven from ./dev-shell.json (deployed to
# ${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/dev-shell.json and read at
# RUNTIME via jq — see ./dev-shell.sh). Always-on (lives in flake.nix
# userModules). cfg.name is still read at eval time here since it fixes the
# binary's own filename, a genuine Nix-build-time concern.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./dev-shell.json);

  # Shell body lives in ./dev-shell.sh. Store paths (bwrap, coreutils, jq)
  # arrive via runtimeEnv instead of ${pkgs.foo} interpolation in the body;
  # p5_store_root / prompt_marker / marker_env are read at runtime from the
  # deployed JSON instead of being Nix-interpolated in.
  devLauncher = pkgs.writeShellApplication {
    name = cfg.name;
    runtimeInputs = [ pkgs.bubblewrap pkgs.coreutils pkgs.jq ];
    runtimeEnv = {
      DEV_SHELL_BWRAP_BIN    = "${pkgs.bubblewrap}/bin/bwrap";
      DEV_SHELL_BASENAME_BIN = "${pkgs.coreutils}/bin/basename";
      DEV_SHELL_READLINK_BIN = "${pkgs.coreutils}/bin/readlink";
      DEV_SHELL_MKTEMP_BIN   = "${pkgs.coreutils}/bin/mktemp";
      DEV_SHELL_RM_BIN       = "${pkgs.coreutils}/bin/rm";
      DEV_SHELL_JQ_BIN       = "${pkgs.jq}/bin/jq";
    };
    text = builtins.readFile ./dev-shell.sh;
  };
in
{
  # Runtime data for dev-shell.sh (Home Manager: xdg.configFile, per the
  # wireguard-wstunnel precedent).
  xdg.configFile."cloud-data/dev-shell.json".source = ./dev-shell.json;

  home.packages = [ pkgs.bubblewrap devLauncher ];

  xdg.desktopEntries.dev = {
    name = "Dev Shell";
    comment = "Bubblewrap sandboxed development environment";
    exec = "dev";
    icon = "utilities-terminal";
    terminal = true;
    categories = [ "Development" "System" ];
  };
}
