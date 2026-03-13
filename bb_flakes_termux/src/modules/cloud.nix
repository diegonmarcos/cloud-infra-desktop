# cloud/ repo — fallback per-service npm install (only if ~/.node_modules missing)
{ config, lib, pkgs, nodejs, ... }:

let
  repoDir = "$HOME/git/cloud";
in {
  home.activation.cloudDeps = lib.hm.dag.entryAfter ["sharedNodeModules"] ''
    (
    trap 'echo "[cloud.nix] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    # Skip if shared node_modules exists (tier 2 handles it)
    if [ -d "$HOME/.node_modules/node_modules" ]; then
      printf "[cloud.nix] Skipped — using shared ~/.node_modules/\n"
      exit 0
    fi

    CLOUD="${repoDir}"
    [ -d "$CLOUD/a_solutions" ] || exit 0

    _npm_install() {
      dir="$1"
      if [ -f "$dir/package.json" ]; then
        if [ ! -d "$dir/node_modules" ] || [ "$dir/package.json" -nt "$dir/node_modules/.package-lock.json" ]; then
          printf "[cloud.nix] fallback npm install: %s\n" "$dir"
          $DRY_RUN_CMD ${nodejs}/bin/npm install --prefix "$dir" --no-audit --no-fund --legacy-peer-deps || true
        fi
      fi
    }

    PATH="${nodejs}/bin:$PATH"
    for svc in "$CLOUD"/a_solutions/*/; do
      case "$svc" in */z_archive/*|*/node_modules/*) continue ;; esac
      _npm_install "$svc"
      [ -d "''${svc}src" ] && _npm_install "''${svc}src"
    done
    ) || echo "[cloud.nix] FAILED — see errors above, activation continues"
  '';
}
