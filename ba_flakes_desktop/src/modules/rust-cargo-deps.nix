# Shared Rust/Cargo deps — single source of truth for all Rust crate dependencies.
#
# Architecture:
#   rust-cargo-deps.nix            ← this file (orchestrator: nix pkgs + prebuild deps)
#   ├── rust-cargo-deps-list.nix    ← static known deps (tokio, reqwest, serde, etc.)
#   └── rust-cargo-deps-cloud.nix   ← auto-merged from cloud-data-deps.json (future)
#
# How it works:
#   1. Nix packages provide the toolchain (rustc, cargo, rust-analyzer, etc.)
#   2. At activation, generates ~/.cargo/prebuild/Cargo.toml with ALL declared crate deps
#   3. Runs `cargo build --release` → compiles deps into ~/.cargo/target
#   4. Any Rust project with CARGO_TARGET_DIR=~/.cargo/target finds deps pre-compiled
#
# Resolution: static list always wins → cloud deps → cargo build
# Skips build if Cargo.toml unchanged since last run.
{ config, lib, pkgs, ... }:

let
  # Resolve "unstable.foo" / "foo" attr paths against pkgs
  resolvePkg = name:
    let
      parts = lib.splitString "." name;
    in
      if builtins.length parts == 2 && builtins.head parts == "unstable"
      then pkgs.unstable.${builtins.elemAt parts 1}
      else pkgs.${name};

  resolvedPackages = map resolvePkg config.rustCargoDeps.nixPackages;

  cargo = pkgs.unstable.cargo;
  rustc = pkgs.unstable.rustc;
in {
  imports = [
    ./rust-cargo-deps-list.nix
    ./rust-cargo-deps-cloud.nix
  ];

  # Install all nix-packaged Rust tools
  home.packages = resolvedPackages;

  # Environment
  home.sessionVariables = {
    CARGO_HOME = "$HOME/.cargo";
    # Shared target dir — compiled deps reused across all Rust projects
    CARGO_TARGET_DIR = "$HOME/.cargo/target";
  };
  home.sessionPath = [ "$HOME/.cargo/bin" ];

  # Activation: merge static + cloud → generate Cargo.toml → cargo build (deps only)
  home.activation.sharedCargoPrebuild = lib.hm.dag.entryAfter ["linkGeneration" "mergeCloudRustDeps"] ''
    CARGO_HOME="$HOME/.cargo"
    PREBUILD="$CARGO_HOME/prebuild"
    CARGO_TOML="$PREBUILD/Cargo.toml"
    MAIN_RS="$PREBUILD/src/main.rs"
    TARGET="$CARGO_HOME/target"
    LOCK="$PREBUILD/.deps-lock.json"
    CLOUD_MERGED="$CARGO_HOME/.cloud-rust-deps-merged.json"

    mkdir -p "$PREBUILD/src" "$TARGET"

    # Static deps from rust-cargo-deps-list.nix → write to file (avoids shell quoting issues)
    STATIC_FILE="$PREBUILD/.static-deps.json"
    cat > "$STATIC_FILE" << 'NIXEOF'
${builtins.toJSON config.rustCargoDeps.static}
NIXEOF

    # Generate Cargo.toml with all merged deps
    PATH="${pkgs.nodejs_22}/bin:$PATH" ${pkgs.nodejs_22}/bin/node -e "
      const fs = require('fs');
      const deps = {};

      // 1. Static deps (highest priority)
      const staticDeps = JSON.parse(fs.readFileSync('$STATIC_FILE', 'utf8'));
      Object.assign(deps, staticDeps);

      // 2. Cloud deps (won't override static)
      const cloudPath = '$CLOUD_MERGED';
      if (fs.existsSync(cloudPath)) {
        try {
          const d = JSON.parse(fs.readFileSync(cloudPath, 'utf8'));
          for (const [k, v] of Object.entries(d)) {
            if (!deps[k]) deps[k] = v;
          }
        } catch (e) { console.error('WARN: ' + e.message); }
      }

      // 3. Check if changed
      const sorted = Object.fromEntries(Object.entries(deps).sort(([a],[b]) => a.localeCompare(b)));
      const lockContent = JSON.stringify(sorted, null, 2) + '\n';
      let changed = true;
      if (fs.existsSync('$LOCK')) {
        try { changed = fs.readFileSync('$LOCK', 'utf8') !== lockContent; } catch {}
      }
      fs.writeFileSync('$LOCK', lockContent);

      if (!changed && fs.existsSync('$TARGET/release/deps')) {
        console.log('[rust-cargo-deps] ~/.cargo/target/ deps up to date (' + Object.keys(deps).length + ' crates)');
        process.exit(0);
      }

      // 4. Generate Cargo.toml
      let toml = '[package]\nname = \"cargo-prebuild\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n';
      for (const [name, ver] of Object.entries(sorted)) {
        // ver is either a quoted string like '\"0.3\"' or an inline table like '{ version = ... }'
        toml += name + ' = ' + ver + '\n';
      }
      toml += '\n[profile.release]\nopt-level = 3\nlto = false\nstrip = false\n';

      fs.writeFileSync('$CARGO_TOML', toml);
      console.log('[rust-cargo-deps] Cargo.toml: ' + Object.keys(deps).length + ' crates');
      console.log('BUILD');
    " 2>&1 | {
      DO_BUILD=false
      while IFS= read -r line; do
        case "$line" in
          BUILD) DO_BUILD=true ;;
          *) printf "%s\n" "$line" ;;
        esac
      done

      if [ "$DO_BUILD" = true ]; then
        # Minimal main.rs (compiles deps without real code)
        echo 'fn main() {}' > "$MAIN_RS"

        printf "[rust-cargo-deps] cargo build --release (pre-compiling deps)...\n"
        export CARGO_HOME="$CARGO_HOME"
        export CARGO_TARGET_DIR="$TARGET"
        export PATH="${pkgs.gcc}/bin:${pkgs.pkg-config}/bin:${pkgs.openssl.dev}/lib/pkgconfig:$PATH"
        export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig"
        export OPENSSL_DIR="${pkgs.openssl.dev}"
        export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
        $DRY_RUN_CMD ${cargo}/bin/cargo build \
          --release \
          --manifest-path "$CARGO_TOML" 2>&1 | \
          grep -E "^(   Compiling|   Finished|error)" | \
          tail -5
        printf "[rust-cargo-deps] Done.\n"
      fi
    }
  '';
}
