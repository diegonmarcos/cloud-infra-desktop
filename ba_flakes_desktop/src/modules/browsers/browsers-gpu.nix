# Universal Chromium-family GPU/compositing patch.
# Source of truth: ./browsers-gpu.json
#
# DESIGN: patches the nixpkgs wrapper script of any chromium-family browser
# to inject GPU flags directly. ONE binary per browser, no wrapper, no
# separate derivation, no /proc/PID/exe gymnastics. Symmetric with Firefox's
# env-var approach (just baking the launch contract into the package).
#
# Why this works: nixpkgs's chromium-family wrappers (bin/<browser>) end
# with `exec ... "$@"` — we substitute that to add our default flags
# BEFORE the user-supplied "$@". The original wrapper still runs (so its
# GIO_EXTRA_MODULES, NIXOS_OZONE_WL handling, etc. still apply); we only
# augment its CLI args.
#
# Imported as a function: `import ./browsers-gpu.nix { inherit pkgs lib; }`
# returns `{ mkChromiumPatched }`. Use:
#
#   programs.chromium.package = mkChromiumPatched "brave" pkgs.unstable.brave;
#
# Trade-off vs the older wrapper+second-derivation design (deleted):
#   + 0 MiB extra disk (no second copy of the 422 MiB brave install)
#   + KDE pin Just Works (one binary, one .desktop, one /proc/PID/exe)
#   + Adding a new chromium browser = one JSON entry + one Nix line
#   - No "untouched original" toggle for fallback testing — flags always on
#
# Adding a new browser:
#   1. Add an entry to browsers-gpu.json with `flags` array
#   2. Set `programs.<browser>.package = mkChromiumPatched "<key>" pkgs.<x>;`
#      (or wherever that browser's package is referenced)
#   3. build.sh switch — patched binary deploys, KDE picks it up

{ pkgs, lib }:
let
  cfg = builtins.fromJSON (builtins.readFile ./browsers-gpu.json);
in
{
  mkChromiumPatched = browserKey: pkg:
    let
      entry = cfg.browsers.${browserKey} or
        (throw "browsers-gpu.json has no entry for '${browserKey}'");
      flagsStr = lib.concatStringsSep " " entry.flags;
    in
    pkg.overrideAttrs (old: {
      # postFixup runs AFTER the original install — patches the deployed
      # wrapper script in-place. substituteInPlace is the standard nixpkgs
      # tool for editing files in $out during a build.
      postFixup = (old.postFixup or "") + ''
        if [ -f $out/bin/${browserKey} ]; then
          substituteInPlace $out/bin/${browserKey} \
            --replace '"$@"' '${flagsStr} "$@"'
        fi
      '';
      meta = (old.meta or {}) // {
        description = (old.meta.description or browserKey)
          + " [GPU-flags-patched: ${flagsStr}]";
      };
    });
}
