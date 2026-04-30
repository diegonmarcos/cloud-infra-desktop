# Brave browser — DEDICATED declarative module.
# Single source of truth for everything Brave-related on this host.
#
# DESIGN (refactored 2026-04-30): SINGLE patched brave install — no
# wrapper, no second derivation, no separate profile dir. Mirrors the
# Firefox approach: GPU flags are baked into the package itself via
# `mkChromiumPatched` (browsers-gpu.nix), so plain `brave` always
# launches with HW compositing + correct video decode.
#
# Removed in this refactor:
#   - `brave-opengl` second binary (had unique /proc/PID/exe for KDE pin)
#   - `Brave-Browser-OpenGL` profile dir (was for the second variant)
#   - 422 MiB of disk for the duplicated brave-gpu derivation
#   - Wrapper script + custom .desktop generation
#
# What stayed declarative:
#   - Force-installed extensions (./brave-extensions.json)
#   - Managed policies (homepage, etc.)
#
# To restore the dual-variant pattern (brave + brave-gpu), revert this
# module to the "wrapper + second derivation" design that lived here
# 2026-04-29..30 (in git history) — but the simpler patched-package
# approach is the recommended default.
#
# Imported by: modules/profiles/7-productivity.nix
#
{ config, pkgs, lib, ... }:
let
  extCfg = builtins.fromJSON (builtins.readFile ./brave-extensions.json);
  gpuLib = import ./browsers-gpu.nix { inherit pkgs lib; };

  # Single patched brave — flags baked into the wrapper script via
  # overrideAttrs/postFixup. Plain `brave` always uses HW compositing.
  bravePatched = gpuLib.mkChromiumPatched "brave" pkgs.unstable.brave;

  bravePolicyDir = ".config/BraveSoftware/Brave-Browser";

  # Force-install JSON for one extension. mechanism — Brave reads
  # External Extensions/<id>.json on startup and auto-installs from the
  # Chrome Web Store.
  mkExtensionFile = id: _meta: lib.nameValuePair
    "${bravePolicyDir}/External Extensions/${id}.json"
    { text = builtins.toJSON {
        external_update_url = "https://clients2.google.com/service/update2/crx";
      };
    };

  # Managed policies — survive Brave updates AND any package hash changes.
  policyDefinitions = {
    "homepage-localhost-8000" = {
      RestoreOnStartup = 4;  # 4 = "Open a list of URLs"
      RestoreOnStartupURLs = [ "http://localhost:8000" ];
      HomepageLocation = "http://localhost:8000";
      HomepageIsNewTabPage = false;
      ShowHomeButton = true;
      NewTabPageLocation = "http://localhost:8000";
    };
  };

  mkPolicyFile = name: content: lib.nameValuePair
    "${bravePolicyDir}/policies/managed/${name}.json"
    { text = builtins.toJSON content; };

  extensionFiles = lib.mapAttrs' mkExtensionFile extCfg.extensions;
  policyFiles    = lib.mapAttrs' mkPolicyFile policyDefinitions;
in
{
  programs.chromium = {
    enable = true;
    # Patched brave — bin/brave's wrapper has GPU flags injected at build
    # time. No runtime wrapper, no separate binary.
    package = bravePatched;
  };

  # Declarative configs land in the SINGLE profile dir.
  home.file = extensionFiles // policyFiles;
}
