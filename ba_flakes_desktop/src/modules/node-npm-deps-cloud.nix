# Cloud npm dependencies — merged from build-flakes_desktop.json (.deps slice)
# at activation time. Source: 2_configs/src/engines/cloud-data-config-derive.ts
# emits build-flakes_desktop.json from external-consumers.json registry.
{ config, lib, pkgs, ... }:

let
  nodejs = pkgs.nodejs_22;
in {
  options.nodeNpmDeps.cloud = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Cloud service npm dependencies (auto-merged from build-flakes_desktop.json .deps)";
  };

  # Activation: read build-flakes_desktop.json .deps → populate nodeNpmDeps.cloud
  config.home.activation.mergeCloudDeps = lib.hm.dag.entryBefore ["sharedNodeModules"] ''
    # Priority chain: synced copy in repo → cloud repo dist → legacy fallback
    CLOUD_BUILD=""
    for _p in \
        "$HOME/git/cloud-unix/ba_flakes_desktop/build-flakes_desktop.json" \
        "$HOME/git/cloud-infra/2_configs/dist/build-flakes_desktop.json" \
        "$HOME/git/cloud-infra/cloud-data/cloud-data-deps.json"; do
      if [ -f "$_p" ]; then CLOUD_BUILD="$_p"; break; fi
    done
    CLOUD_OUT="$HOME/.node_modules/.cloud-deps-merged.json"

    if [ -n "$CLOUD_BUILD" ]; then
      PATH="${nodejs}/bin:$PATH" ${nodejs}/bin/node -e "
        const fs = require('fs');
        const deps = {};
        try {
          const raw = JSON.parse(fs.readFileSync('$CLOUD_BUILD', 'utf8'));
          // build-flakes_desktop.json wraps deps under .deps; legacy
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
      printf "[node-npm-deps-cloud] No build-flakes_desktop.json or cloud-data-deps.json found\n"
      echo '{}' > "$CLOUD_OUT" 2>/dev/null || true
    fi
  '';
}
