# Cloud npm dependencies — merged from build-flakes_termux.json (.deps slice)
# at activation time. Source: 2_configs/src/engines/cloud-data-config-derive.ts
# emits build-flakes_termux.json from external-consumers.json registry.
args@{ config, lib, pkgs, ... }:

let
  # Take nodejs from module args (flake.nix _module.args = pkgsUnstable
  # nodejs_22, i.e. >=22.12) — hardcoding pkgs.nodejs_22 here pinned every
  # npm install to 24.05's node 22.10, which vite 8 / unplugin 3 reject
  # (the EBADENGINE spam) and which native addons compiled against.
  nodejs = args.nodejs or pkgs.nodejs_22;
in {
  options.nodeNpmDeps.cloud = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Cloud service npm dependencies (auto-merged from build-flakes_termux.json .deps)";
  };

  # Activation: read build-flakes_termux.json .deps → populate nodeNpmDeps.cloud
  # body in scripts/merge-cloud-deps.sh
  config.home.activation.mergeCloudDeps = lib.hm.dag.entryBefore ["sharedNodeModules"] ''
    NODEJS_DIR="${nodejs}/bin" ${pkgs.bash}/bin/bash ${./scripts/merge-cloud-deps.sh} || true
  '';
}
