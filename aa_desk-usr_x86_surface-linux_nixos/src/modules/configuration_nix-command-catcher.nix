# nix-command-catcher — force EVERY heavy `nix`/`nixos-rebuild` invocation
# through the existing `nix-switch-progress-wrap` catcher, no matter who
# typed it (Diego at a raw shell, an agent, a stray script) and no matter
# whether it went through build.sh or not.
#
# WHY (2026-07-26 freeze root cause): this is an 8-core/8GB box. A naked
# `nix build` / `nix develop` / `nix run` / `nixos-rebuild switch|boot|
# build|test|dry-build` run OUTSIDE build.sh's progress-wrap pipeline skips
# the idle-class scheduling + PSI-aware UI that keeps builds from starving
# the interactive session (see configuration_nix.nix:35-40) and gives no
# visible signal that a heavy job is running at all — the same class of
# "silent kswapd IO-trash / freeze" incident already fixed once for
# build.sh's own call path (nix-switch-progress.nix) but never closed for
# anyone invoking `nix`/`nixos-rebuild` directly. This module closes that
# gap at the PATH level instead of relying on every caller to remember to
# route through build.sh.
#
# Mechanism: two `writeShellApplication` wrappers named `nix` and
# `nixos-rebuild` are installed into environment.systemPackages with
# lib.hiPrio so they win PATH resolution over the real packages (nix is
# provided transitively by nixpkgs/the nix daemon package, nixos-rebuild by
# the nixos-rebuild package pulled in by the system toolchain). Verb
# allowlists come from nix-command-catcher.json — nothing is hardcoded in
# the shell body:
#   - recursion guard: NSP_ACTIVE set => exec the real absolute-store-path
#     binary immediately (never resolve the real binary via PATH, or the
#     wrapper execs itself).
#   - first non-flag arg NOT in the allowlist => exec real binary directly,
#     no UI (covers `nix eval`, `nix path-info`, `nix flake show`,
#     `nixos-rebuild list-generations`, etc).
#   - first non-flag arg IS heavy AND nix-switch-progress-wrap is on PATH
#     AND a graphical session is present (DISPLAY/WAYLAND_DISPLAY) => exec
#     `NSP_ACTIVE=1 nix-switch-progress-wrap <real-binary> "$@"`.
#   - heavy but headless (no graphical session) or catcher missing => just
#     set NSP_ACTIVE and exec the real binary directly (no window; must
#     never block a headless/CI/SSH invocation, same invariant as the
#     catcher itself).
{ config, pkgs, lib, ... }:

let
  cfg = builtins.fromJSON (builtins.readFile ./nix-command-catcher.json);

  # Bash array literal from a Nix string list, e.g. ("build" "develop" "run")
  bashArray = verbs: "(" + lib.concatMapStringsSep " " (v: "\"${v}\"") verbs + ")";

  mkCatcher = { name, realBin, heavyVerbs }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ ];
      text = ''
        # Generated from configuration_nix-command-catcher.nix — do not edit by hand.
        # Verb allowlist is data-driven from nix-command-catcher.json (heavy_${
          if name == "nix" then "nix_verbs" else "nixos_rebuild_verbs"
        }).
        REAL="${realBin}"

        # Recursion guard: once inside a catcher-spawned invocation, go
        # straight to the real binary — never re-enter this wrapper.
        if [ -n "''${NSP_ACTIVE:-}" ]; then
          exec "$REAL" "$@"
        fi

        HEAVY_VERBS=${bashArray heavyVerbs}

        # First non-flag argument is the verb we gate on.
        verb=""
        for arg in "$@"; do
          case "$arg" in
            -*) continue ;;
            *) verb="$arg"; break ;;
          esac
        done

        is_heavy=0
        for v in "''${HEAVY_VERBS[@]}"; do
          if [ "$verb" = "$v" ]; then
            is_heavy=1
            break
          fi
        done

        if [ "$is_heavy" -ne 1 ]; then
          exec "$REAL" "$@"
        fi

        export NSP_ACTIVE=1

        if command -v nix-switch-progress-wrap >/dev/null 2>&1 \
          && { [ -n "''${DISPLAY:-}" ] || [ -n "''${WAYLAND_DISPLAY:-}" ]; }; then
          exec nix-switch-progress-wrap "$REAL" "$@"
        fi

        # Headless or catcher not installed: no window, never block.
        exec "$REAL" "$@"
      '';
    };

  nixCatcher = mkCatcher {
    name = "nix";
    realBin = "${pkgs.nix}/bin/nix";
    heavyVerbs = cfg.heavy_nix_verbs;
  };

  nixosRebuildCatcher = mkCatcher {
    name = "nixos-rebuild";
    realBin = "${pkgs.nixos-rebuild}/bin/nixos-rebuild";
    heavyVerbs = cfg.heavy_nixos_rebuild_verbs;
  };
in {
  environment.systemPackages = [
    (lib.hiPrio nixCatcher)
    (lib.hiPrio nixosRebuildCatcher)
  ];
}
