# cloud/ repo — npm install for all services with package.json
{ config, lib, pkgs, nodejs, ... }:

let
  repoDir = "$HOME/git/cloud";
in {
  home.activation.cloudDeps = lib.hm.dag.entryAfter ["linkGeneration"] ''
    CLOUD="${repoDir}"
    [ -d "$CLOUD/a_solutions" ] || exit 0

    _npm_install() {
      dir="$1"
      if [ -f "$dir/package.json" ]; then
        if [ ! -d "$dir/node_modules" ] || [ "$dir/package.json" -nt "$dir/node_modules/.package-lock.json" ]; then
          printf "[cloud.nix] npm install: %s\n" "$dir"
          $DRY_RUN_CMD ${nodejs}/bin/npm install --prefix "$dir" --no-audit --no-fund || true
        fi
      fi
    }

    PATH="${nodejs}/bin:$PATH"
    for svc in "$CLOUD"/a_solutions/*/; do
      case "$svc" in */z_archive/*|*/node_modules/*) continue ;; esac
      _npm_install "$svc"
      [ -d "''${svc}src" ] && _npm_install "''${svc}src"
    done
  '';
}
