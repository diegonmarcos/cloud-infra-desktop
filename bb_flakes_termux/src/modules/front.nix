# front/ repo — symlink shared node_modules into projects (ESM resolution needs local node_modules/)
# Fallback: per-project npm install if shared dir missing
{ config, lib, pkgs, nodejs, ... }:

let
  repoDir = "$HOME/git/front";
in {
  home.activation.frontDeps = lib.hm.dag.entryAfter ["sharedNodeModules"] ''
    (
    trap 'echo "[front.nix] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR

    FRONT="${repoDir}"
    [ -d "$FRONT" ] || exit 0
    SHARED="$HOME/.node_modules/node_modules"

    if [ -d "$SHARED" ]; then
      # ESM resolution walks up dirs — symlink shared node_modules at front/ root
      if [ ! -d "$FRONT/node_modules" ] || [ -L "$FRONT/node_modules" ]; then
        ln -sfn "$SHARED" "$FRONT/node_modules"
      fi
      printf "[front.nix] Symlinked shared node_modules into front/\n"
    else
      # Fallback: per-project npm install
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
    fi
    ) || echo "[front.nix] FAILED — see errors above, activation continues"
  '';
}
