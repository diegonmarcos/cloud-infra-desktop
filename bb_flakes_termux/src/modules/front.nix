# front/ repo — npm install for all projects with package.json
{ config, lib, pkgs, nodejs, ... }:

let
  repoDir = "$HOME/git/front";
in {
  home.activation.frontDeps = lib.hm.dag.entryAfter ["linkGeneration"] ''
    FRONT="${repoDir}"
    [ -d "$FRONT" ] || exit 0

    _npm_install() {
      dir="$1"
      if [ -f "$dir/package.json" ]; then
        if [ ! -d "$dir/node_modules" ] || [ "$dir/package.json" -nt "$dir/node_modules/.package-lock.json" ]; then
          printf "[front.nix] npm install: %s\n" "$dir"
          $DRY_RUN_CMD ${nodejs}/bin/npm install --prefix "$dir" --no-audit --no-fund || true
        fi
      fi
    }

    PATH="${nodejs}/bin:$PATH"

    # Root monorepo
    _npm_install "$FRONT"

    # Category/project level (a-Portals/*, b-Profiles/*, c-Tools/*, d-Cloud/*, e-Root/*)
    for category in "$FRONT"/*/; do
      case "$category" in */node_modules/*|*/z_archive/*|*/.git/*) continue ;; esac
      _npm_install "$category"
      for project in "$category"*/; do
        case "$project" in */node_modules/*|*/dist/*|*/static/*|*/z_archive/*) continue ;; esac
        _npm_install "$project"
      done
    done
  '';
}
