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
  config.home.activation.mergeCloudDeps = lib.hm.dag.entryBefore ["sharedNodeModules"] ''
    # Priority chain: synced copy in repo → cloud repo dist → legacy fallback
    CLOUD_BUILD=""
    for _p in \
        "$HOME/git/unix/bb_flakes_termux/build-flakes_termux.json" \
        "$HOME/git/cloud/2_configs/dist/build-flakes_termux.json" \
        "$HOME/git/cloud/cloud-data/cloud-data-deps.json"; do
      if [ -f "$_p" ]; then CLOUD_BUILD="$_p"; break; fi
    done
    CLOUD_OUT="$HOME/.node_modules/.cloud-deps-merged.json"

    if [ -n "$CLOUD_BUILD" ]; then
      PATH="${nodejs}/bin:$PATH" ${nodejs}/bin/node -e "
        const fs = require('fs');
        const deps = {};
        try {
          const raw = JSON.parse(fs.readFileSync('$CLOUD_BUILD', 'utf8'));
          // build-flakes_termux.json wraps deps under .deps; legacy
          // cloud-data-deps.json had the same shape at the root.
          const d = raw.deps || raw;
          const take = (obj) => {
            for (const [k, v] of Object.entries(obj || {})) {
              if (!deps[k] || v > deps[k]) deps[k] = v;
            }
          };
          take(d.node?.merged?.dependencies);
          take(d.node?.merged?.devDependencies);
        } catch (e) { console.error('WARN: cloud-deps: ' + e.message); }
        fs.writeFileSync('$CLOUD_OUT', JSON.stringify(deps, null, 2) + '\n');
        console.log('[node-npm-deps-cloud] ' + Object.keys(deps).length + ' cloud deps from ' + '$CLOUD_BUILD');
      " || printf "[node-npm-deps-cloud] WARN: merge failed\n"
    else
      printf "[node-npm-deps-cloud] No build-flakes_termux.json or cloud-data-deps.json found\n"
      echo '{}' > "$CLOUD_OUT" 2>/dev/null || true
    fi
  '';
}
