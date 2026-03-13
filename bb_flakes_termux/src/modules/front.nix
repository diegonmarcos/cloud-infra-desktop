# front/ repo — fallback per-project npm install (only if ~/.node_modules missing)
{ config, lib, pkgs, nodejs, ... }:

let
  repoDir = "$HOME/git/front";
in {
  home.activation.frontDeps = lib.hm.dag.entryAfter ["sharedNodeModules"] ''
    (
    trap 'echo "[front.nix] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    # Skip if shared node_modules exists (tier 2 handles it)
    if [ -d "$HOME/.node_modules/node_modules" ]; then
      printf "[front.nix] Skipped — using shared ~/.node_modules/\n"
      exit 0
    fi

    FRONT="${repoDir}"
    [ -d "$FRONT" ] || exit 0

    _npm_install() {
      dir="$1"
      if [ -f "$dir/package.json" ]; then
        if [ ! -d "$dir/node_modules" ] || [ "$dir/package.json" -nt "$dir/node_modules/.package-lock.json" ]; then
          printf "[front.nix] fallback npm install: %s\n" "$dir"
          $DRY_RUN_CMD ${nodejs}/bin/npm install --prefix "$dir" --no-audit --no-fund --legacy-peer-deps || true
        fi
      fi
    }

    PATH="${nodejs}/bin:$PATH"
    _npm_install "$FRONT"

    for category in "$FRONT"/*/; do
      case "$category" in */node_modules/*|*/z_archive/*|*/.git/*) continue ;; esac
      _npm_install "$category"
      for project in "$category"*/; do
        case "$project" in */node_modules/*|*/dist/*|*/static/*|*/z_archive/*) continue ;; esac
        _npm_install "$project"
      done
    done
    ) || echo "[front.nix] FAILED — see errors above, activation continues"
  '';
}
