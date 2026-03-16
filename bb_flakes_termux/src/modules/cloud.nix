# cloud/ repo — symlink shared node_modules into services (ESM resolution needs local node_modules/)
# Fallback: per-service npm install if shared dir missing
{ config, lib, pkgs, nodejs, ... }:

let
  repoDir = "$HOME/git/cloud";
in {
  home.activation.cloudDeps = lib.hm.dag.entryAfter ["sharedNodeModules"] ''
    (
    trap 'echo "[cloud.nix] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR

    CLOUD="${repoDir}"
    [ -d "$CLOUD/a_solutions" ] || exit 0
    SHARED="$HOME/.node_modules/node_modules"

    if [ -d "$SHARED" ]; then
      # ESM resolution walks up dirs looking for node_modules/ — symlink shared into each service
      for svc in "$CLOUD"/a_solutions/*/; do
        case "$svc" in */z_archive/*|*/node_modules/*) continue ;; esac
        [ -f "''${svc}package.json" ] || [ -f "''${svc}src/package.json" ] || continue
        # Service root: symlink if not a real dir (preserve manually-installed deps)
        if [ ! -d "''${svc}node_modules" ] || [ -L "''${svc}node_modules" ]; then
          ln -sfn "$SHARED" "''${svc}node_modules"
        fi
      done
      printf "[cloud.nix] Symlinked shared node_modules into %d services\n" \
        "$(find "$CLOUD/a_solutions" -maxdepth 2 -name node_modules -lname "$SHARED" 2>/dev/null | wc -l)"
    else
      # Fallback: per-service npm install
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
    fi
    ) || echo "[cloud.nix] FAILED — see errors above, activation continues"
  '';
}
