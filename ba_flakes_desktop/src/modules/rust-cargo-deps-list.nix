# Static list of Rust/Cargo dependencies — always pre-compiled.
# Declarative baseline: Nix packages (toolchain) + crate deps (pre-built into ~/.cargo/target).
#
# Architecture mirrors node-npm-deps-list.nix:
#   nixPackages:  Nix store packages (rustc, cargo, cargo-edit, etc.)
#   crateDeps:    Crate dependencies pre-compiled into shared ~/.cargo/target
#                 Merged from: static list (this file) + cloud-data + front-data
{ lib, ... }:

{
  options.rustCargoDeps = {
    nixPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Nix package attr names for Rust toolchain and cargo subcommands";
    };
    static = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Static crate dependencies to pre-compile (name -> version spec)";
    };
  };

  config.rustCargoDeps = {
    # ── Nix packages (toolchain + cargo subcommands) ──
    nixPackages = [
      # Toolchain (unstable for latest versions)
      "unstable.rustc"
      "unstable.cargo"
      "unstable.rust-analyzer"
      "unstable.clippy"
      "unstable.rustfmt"

      # Cargo subcommands
      "cargo-edit"       # cargo add/rm/upgrade
      "cargo-watch"      # cargo watch -x check
      "cargo-audit"      # security audit

      # Build dependencies (needed by many crates)
      "pkg-config"
      "openssl"
    ];

    # ── Crate dependencies (pre-compiled into ~/.cargo/target) ──
    # Snapshot merged from all Cargo.toml across cloud/ + cloud-data/ repos.
    static = {
      # ── Async runtime ──
      "tokio" = ''{ version = "1", features = ["full"] }'';
      "futures" = ''"0.3"'';
      "async-trait" = ''"0.1"'';

      # ── HTTP ──
      "reqwest" = ''{ version = "0.12", features = ["rustls-tls", "json"], default-features = false }'';
      "axum" = ''"0.8"'';
      "url" = ''"2"'';

      # ── Serialization ──
      "serde" = ''{ version = "1", features = ["derive"] }'';
      "serde_json" = ''"1"'';

      # ── DNS ──
      "trust-dns-resolver" = ''"0.23"'';

      # ── Date/time ──
      "chrono" = ''{ version = "0.4", features = ["serde"] }'';

      # ── Error handling ──
      "anyhow" = ''"1"'';

      # ── Filesystem ──
      "dirs" = ''"5"'';

      # ── Templating ──
      "tera" = ''"1"'';

      # ── SSH ──
      "russh" = ''"0.46"'';
      "russh-keys" = ''"0.46"'';

      # ── Logging ──
      "tracing" = ''"0.1"'';
      "tracing-subscriber" = ''{ version = "0.3", features = ["env-filter"] }'';

      # ── Crypto/IDs ──
      "uuid" = ''{ version = "1", features = ["v4"] }'';
      "md5" = ''"0.7"'';

      # ── WebSocket ──
      "tokio-tungstenite" = ''{ version = "0.26", features = ["native-tls"] }'';

      # ── AI/Agent ──
      "rig-core" = ''{ version = "0.31", features = ["rmcp"] }'';
      "rmcp" = ''{ version = "0.13", features = ["client", "transport-streamable-http-client", "transport-streamable-http-client-reqwest"] }'';
    };
  };
}
