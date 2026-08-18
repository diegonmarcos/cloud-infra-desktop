{
  description = "Nix-on-Droid Termux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-new.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-on-droid = {
      # release-24.05 hasn't moved since 2024-07-07 (effectively abandoned) —
      # its fixed-output-derivation binary pins (e.g. proot-termux-static)
      # decayed out of the substituter cache, breaking CI with
      # "path ... does not exist and cannot be created" (2026-07-03).
      # master is actively maintained and has current, fetchable pins.
      url = "github:nix-community/nix-on-droid/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # my-ai owns the Claude config; this flake only deploys it. Consumed as a real
    # flake (not `flake = false`) so we read the `claudeAssets` OUTPUT rather than
    # reaching into a source tree — same input ba_flakes_desktop already uses.
    # A relative `path:../../da_my-ai` is NOT an option: nix 2.18 rejects it with
    # "relative path points outside of its parent's store path", so this is a remote
    # ref and asset edits must be pushed before a switch will see them.
    my-ai = {
      url = "github:diegonmarcos/cloud-unix?dir=da_my-ai";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-new, nixpkgs-unstable, nix-on-droid, home-manager, my-ai }:
    let
      pkgsNew = import nixpkgs-new { system = "aarch64-linux"; };
      pkgsUnstable = import nixpkgs-unstable { system = "aarch64-linux"; config.allowUnfree = true; };

      # Node identity for DTK webhooks (ntfy topic = dtk-cmd-<dtkNode>).
      # Source of truth: build.json -> defaults.dtk_node. Termux can't
      # sethostname() on Android (no root) so `hostname -s` returns
      # "localhost" — useless as a topic key. This makes the identity
      # declarative + data-driven instead.
      # ./build.json is vendored into src/ by build.sh before eval — the flake
      # must reference nothing outside src/ (path: flake; a ../ ref escaping src/
      # forces nix to copy the whole 3.6GB repo and proot dies mid-copy).
      buildJson = builtins.fromJSON (builtins.readFile ./build.json);
      dtkNode = buildJson.defaults.dtk_node or "unset";

      # ONE nerdfonts derivation shared by environment.packages and the
      # ~/.termux/font.ttf home.file (two different `override` calls used to
      # build two separate huge packages).
      jbMonoNerd = (import nixpkgs { system = "aarch64-linux"; }).nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; };

      # Build termux-am from nix-on-droid source (provides `am` for Android intents)
      termux-am = (import nixpkgs { system = "aarch64-linux"; }).callPackage
        "${nix-on-droid}/pkgs/android-integration/termux-am.nix" {};

      # bash + zsh aliases, DERIVED from the same single source of truth the
      # fish layer uses (modules/data/fish-commands.json, entries flagged
      # shared:true). Hand-keeping a second copy here is what produced the
      # `up` shadow that hid the managed fish function for months.
      # fish is NOT fed from here — fish.nix owns the full set — so the two
      # definitions can never collide on a key.
      fishCmds = builtins.fromJSON (builtins.readFile ./modules/data/fish-commands.json);
      sharedAliases = builtins.listToAttrs (map
        (a: { name = a.name; value = a.cmd; })
        (builtins.filter (a: a.shared or false) fishCmds.aliases));
    in
    {
      nixOnDroidConfigurations.default = nix-on-droid.lib.nixOnDroidConfiguration {
        pkgs = import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; };
        modules = [
          ({ config, lib, pkgs, ... }: {
            imports = [
              ./modules/system.nix
              ./modules/environment-packages.nix
            ];

            # Derived in the outer `let` and handed to the imported system modules.
            _module.args = {
              inherit pkgsNew pkgsUnstable termux-am jbMonoNerd dtkNode nix-on-droid;
            };

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { config, pkgs, lib, ... }: {
              _module.args.nodejs = pkgsUnstable.nodejs_22;
              # wstunnel 7.x (Rust) lives in pkgsUnstable. The old wstunnel 0.5.x
              # in pinned nixos-24.05 is Haskell and pulls connection-0.3.1 which
              # is marked broken upstream — blocking every home-manager switch.
              _module.args.wstunnel = pkgsUnstable.wstunnel;
              # patchelf 0.15.0 (pinned nixos-24.05) crashes with
              # "Assertion !section.empty() failed" rewriting the interpreter
              # on large (~70MB+) binaries that are already nix-patched —
              # exactly what the fetched my-webserver blob
              # is (patched once already by the CI job that publishes it, at
              # a different glibc store path than this flake's own pin).
              # Fixed in later patchelf releases; pkgsUnstable has one.
              _module.args.patchelfUnstable = pkgsUnstable.patchelf;
              # my-ai owns the Claude config — claude/claude.nix reads its
              # `claudeAssets` output.
              _module.args.claudeSrc = my-ai.claudeAssets;
              # Derived in the outer `let` (one shared nerdfonts derivation; aliases
              # generated from modules/data/fish-commands.json).
              _module.args.jbMonoNerd = jbMonoNerd;
              _module.args.sharedAliases = sharedAliases;

              imports = [
                ./claude/claude.nix
                ./modules/termux-platform.nix
                ./modules/hm-runtime.nix
                ./modules/gemini.nix
                ./modules/common.nix
                ./modules/packages.nix
                ./modules/curl-wget-wrapper.nix
                ./modules/node-npm-deps.nix
                ./modules/node-bins.nix
                ./modules/my-webserver
                ./modules/cloud-ide-sshd
                ./modules/wireguard.nix
                ./modules/wireguard-wstunnel.nix
              ];
              home.stateVersion = "24.05";

            };
          })
        ];
      };

      # ── termux-cache-image: LAYERED image of the nix-on-droid closure ──
      # One layer per store path (dockerTools.buildLayeredImage) → skopeo
      # (no Docker daemon needed on Android — see build.sh's
      # ghcr_pull_layered_skopeo) skips unchanged layers, so `build.sh pull`
      # fetches only the store paths that actually changed instead of
      # re-downloading the whole multi-GB nar. Pushed to GHCR by the CI
      # export step (GHCR_PUSH=1); consumed by `cmd_pull` (the nar.zst path
      # is kept as the fallback). Mirrors ba_flakes_desktop's hm-cache-image.
      packages.aarch64-linux.termux-cache-image = pkgsNew.dockerTools.buildLayeredImage {
        name = "unix-termux-cache";
        tag = "latest";
        maxLayers = 120;
        contents = [ self.nixOnDroidConfigurations.default.activationPackage ];
        config.Labels = {
          "org.opencontainers.image.description" = "Termux (nix-on-droid) activation closure as layered store paths (incremental GHCR cache).";
          "org.opencontainers.image.source" = "https://github.com/diegonmarcos/cloud-unix";
        };
      };
    };
}
