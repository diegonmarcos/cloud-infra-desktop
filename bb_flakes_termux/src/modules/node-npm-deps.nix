# Shared ~/.node_modules — single npm install for all repos.
#
# Architecture:
#   node-npm-deps.nix          ← this file (orchestrator: merge + install)
#   ├── node-npm-deps-list.nix  ← static known deps (tsx, MCP SDK, fastify, etc.)
#   ├── node-npm-deps-cloud.nix ← auto-merged from build-flakes_termux.json (.deps)
#   └── node-npm-deps-front.nix ← auto-merged from front-data/front-deps.json
#
# Resolution: static list always wins → cloud deps → front deps → npm install
# Skips install if package.json unchanged since last run.
args@{ config, lib, pkgs, ... }:

let
  # Take nodejs from module args (flake.nix _module.args = pkgsUnstable
  # nodejs_22, i.e. >=22.12) — hardcoding pkgs.nodejs_22 here pinned every
  # npm install to 24.05's node 22.10, which vite 8 / unplugin 3 reject
  # (the EBADENGINE spam) and which native addons compiled against.
  nodejs = args.nodejs or pkgs.nodejs_22;
in {
  imports = [
    ./node-npm-deps-list.nix
    ./node-npm-deps-cloud.nix
    ./node-npm-deps-front.nix
  ];

  # Set NODE_PATH so all tools resolve from shared dir
  home.sessionVariables.NODE_PATH = "$HOME/.node_modules/node_modules";

  # Add .bin to PATH for CLI tools (tsx, tsc, vite, eslint, prettier, etc.)
  home.sessionPath = [ "$HOME/.node_modules/node_modules/.bin" ];

  # Activation: merge all 3 sources → generate package.json → npm install
  # merge + install — body in scripts/shared-node-modules.sh
  home.activation.sharedNodeModules = lib.hm.dag.entryAfter ["linkGeneration" "mergeCloudDeps" "mergeFrontDeps"] ''
    NODEJS_DIR="${nodejs}/bin" \
    STATIC_DEPS='${builtins.toJSON config.nodeNpmDeps.static}' \
    ${pkgs.bash}/bin/bash ${./scripts/shared-node-modules.sh} || true
  '';

  # Symlink node_modules into stdio MCP src/ dirs so ESM imports resolve.
  # NODE_PATH only works for CJS require() — ESM import ignores it and walks
  # the filesystem up from the importing file looking for node_modules/.
  # ESM symlinks — body in scripts/mcp-node-symlinks.sh
  home.activation.mcpNodeModulesSymlinks = lib.hm.dag.entryAfter ["sharedNodeModules"] ''
    ${pkgs.bash}/bin/bash ${./scripts/mcp-node-symlinks.sh} || true
  '';
}
