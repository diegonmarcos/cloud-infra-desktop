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
# Data-driven from ./dev-shell.json. Always-on (lives in flake.nix userModules).
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./dev-shell.json);
  p5  = cfg.p5_store_root;

  devLauncher = pkgs.writeShellScriptBin cfg.name ''
    set -u
    P5=${lib.escapeShellArg p5}
    BWRAP=${pkgs.bubblewrap}/bin/bwrap
    BN=${pkgs.coreutils}/bin/basename
    RL=${pkgs.coreutils}/bin/readlink

    if [ ! -d "$P5/nix/store" ]; then
      echo "${cfg.name}: dev-store not present at $P5 — is p5 (/mnt/shared-lib) mounted?" >&2
      exit 1
    fi
    # The profile gcroot ($P5/profile) points to a LOGICAL /nix/store path that
    # only resolves INSIDE the namespace. Resolve the PHYSICAL p5 path so the
    # pre-check works outside AND the binaries' interpreter (/nix/store/…-glibc)
    # still resolves inside (where /nix/store == the p5 store).
    PHYS="$P5/nix/store/$("$BN" "$("$RL" "$P5/profile" 2>/dev/null)" 2>/dev/null)"
    if [ ! -x "$PHYS/bin/bash" ]; then
      echo "${cfg.name}: dev profile not built yet — run:  ~/git/unix/bc_flakes_dev-store/build.sh ship" >&2
      exit 1
    fi

    # Host env passes through (no --clearenv) so DISPLAY/WAYLAND_DISPLAY/HOME/TERM
    # just work; we only override PATH (→ the p5 profile) and set the marker.
    base=( "$BWRAP"
      --dev-bind / /
      --bind "$P5/nix/store" /nix/store
      --setenv ${cfg.marker_env} 1
      --setenv CARGO_HOME "$HOME/.cargo"
      --setenv CARGO_TARGET_DIR "$HOME/.cargo/target"
      --setenv PATH "$PHYS/bin:$HOME/.cargo/bin" )

    if [ "''${1:-}" = "--" ]; then
      shift
      exec "''${base[@]}" "$PHYS/bin/bash" -c 'exec "$@"' _ "$@"
    fi

    # Interactive: a throwaway rcfile (host /tmp is bound in) sets the [dev] prompt.
    RC="$(${pkgs.coreutils}/bin/mktemp /tmp/dev-rc.XXXXXX)"
    printf 'PS1=%s\n' '"${cfg.prompt_marker}\w \$ "' > "$RC"
    "''${base[@]}" "$PHYS/bin/bash" --rcfile "$RC" -i
    rc=$?
    ${pkgs.coreutils}/bin/rm -f "$RC"
    exit $rc
  '';
in
{
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
