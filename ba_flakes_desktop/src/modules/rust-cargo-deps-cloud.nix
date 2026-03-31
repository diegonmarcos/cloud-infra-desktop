# Cloud Rust/Cargo dependencies — merged from cloud-data-deps.json at activation time.
# Reads the `rust` section when it exists (future-ready).
{ config, lib, pkgs, ... }:

{
  options.rustCargoDeps.cloud = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Cloud service Rust crate dependencies (auto-merged from cloud-data-deps.json)";
  };

  # Activation: read cloud-data-deps.json rust section → write merged output
  config.home.activation.mergeCloudRustDeps = lib.hm.dag.entryBefore ["sharedCargoPrebuild"] ''
    CLOUD_DEPS="$HOME/git/cloud/cloud-data/cloud-data-deps.json"
    CLOUD_OUT="$HOME/.cargo/.cloud-rust-deps-merged.json"

    mkdir -p "$HOME/.cargo"

    if [ -f "$CLOUD_DEPS" ]; then
      PATH="${pkgs.nodejs_22}/bin:$PATH" ${pkgs.nodejs_22}/bin/node -e "
        const fs = require('fs');
        const deps = {};
        try {
          const d = JSON.parse(fs.readFileSync('$CLOUD_DEPS', 'utf8'));
          const take = (obj) => {
            for (const [k, v] of Object.entries(obj || {})) {
              if (!deps[k]) deps[k] = v;
            }
          };
          take(d.rust?.merged?.dependencies);
          take(d.rust?.crates);
        } catch (e) { console.error('WARN: cloud-rust-deps: ' + e.message); }
        fs.writeFileSync('$CLOUD_OUT', JSON.stringify(deps, null, 2) + '\n');
        const n = Object.keys(deps).length;
        if (n > 0) console.log('[rust-cargo-deps-cloud] ' + n + ' cloud rust deps extracted');
      " || printf "[rust-cargo-deps-cloud] WARN: merge failed\n"
    else
      printf "[rust-cargo-deps-cloud] No cloud-data-deps.json found\n"
      echo '{}' > "$CLOUD_OUT" 2>/dev/null || true
    fi
  '';
}
