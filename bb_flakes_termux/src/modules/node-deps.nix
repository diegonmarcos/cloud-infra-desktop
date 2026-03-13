# Shared ~/.node_modules — single install for all repos
# Resolution chain: system (nix) → ~/.node_modules → repo/node_modules (fallback)
{ config, lib, pkgs, nodejs, ... }:

{
  # Deploy master package.json to ~/.node_modules/
  home.file.".node_modules/package.json".source = ./dotfiles/node/package.json;

  # Set NODE_PATH so all tools resolve from shared dir
  home.sessionVariables.NODE_PATH = "$HOME/.node_modules/node_modules";

  # Activation: npm install into shared dir if package.json changed
  home.activation.sharedNodeModules = lib.hm.dag.entryAfter ["linkGeneration"] ''
    NODE_MODULES="$HOME/.node_modules"
    PKG_JSON="$NODE_MODULES/package.json"
    LOCK="$NODE_MODULES/node_modules/.package-lock.json"

    if [ -f "$PKG_JSON" ]; then
      if [ ! -d "$NODE_MODULES/node_modules" ] || [ "$PKG_JSON" -nt "$LOCK" ]; then
        printf "[node-deps.nix] npm install: ~/.node_modules/\n"
        PATH="${nodejs}/bin:$PATH" $DRY_RUN_CMD ${nodejs}/bin/npm install \
          --prefix "$NODE_MODULES" \
          --no-audit --no-fund --legacy-peer-deps || true
      else
        printf "[node-deps.nix] ~/.node_modules/ is up to date\n"
      fi
    fi
  '';
}
