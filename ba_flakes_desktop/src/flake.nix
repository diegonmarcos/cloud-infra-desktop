{
  description = "Diego's Home Manager - Standalone Multi-Distro Setup with Container Support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nur.url = "github:nix-community/NUR";

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Plasma configuration manager
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # ── Cross-repo / sibling-monorepo data sources ───────────────────────────
    # These were previously imported via relative `../../../../` paths that
    # escape the flake source dir. That breaks under any flake ref style that
    # copies the source into /nix/store (which is all of them — `path:`,
    # `git+file:` with the inner dir, sandboxed evals, etc.) because `..`
    # resolves outside the store path.
    #
    # The declarative answer is github URLs, pinned in flake.lock. Local
    # hacking workflow: `nix flake lock --update-input <name>` after pushing
    # to the monorepo, OR `--override-input <name> path:/abs/path` for an
    # in-flight uncommitted edit.
    #
    # All three are `flake = false` — they're plain data trees, not flakes.

    # Sibling subdirs of the diegonmarcos/cloud-unix monorepo. `?dir=` only steers
    # flake.nix discovery; with `flake = false` it's a no-op, so importing
    # modules reach into the fetched tree via `"${inputs.unix-repo}/subdir/file"`.
    # Both qute-broker and termux-flake share the same fetch — same repo,
    # different paths inside it — and the lockfile dedupes the github fetch.
    unix-repo = {
      url = "github:diegonmarcos/cloud-unix";
      flake = false;
    };

    # cloud repo — different repo entirely.
    cloud-repo = {
      url = "github:diegonmarcos/cloud-infra";
      flake = false;
    };

    # my-ai Rust CLI: pre-built binary from GH Release, hashes auto-updated by GHA.
    my-ai-src = {
      url = "github:diegonmarcos/cloud-unix?dir=da_my-ai";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, nur, sops-nix, plasma-manager, unix-repo, cloud-repo, my-ai-src, ... }@inputs:
    let
      system = "x86_64-linux";

      # Package overlays
      overlays = [
        nur.overlays.default
        (final: prev: {
          unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
          # Custom packages (AI CLIs, etc.)
          customPkgs = import ./modules/packages { pkgs = final; };
          # ttyd with mobile keyboard (PR #1504)
          ttyd = prev.ttyd.overrideAttrs (old: {
            version = "1.7.7-mobile-keyboard";
            src = final.fetchFromGitHub {
              owner = "someonegg";
              repo = "ttyd";
              rev = "051962523e5e5e61ffbf627a27134c2a9484e0a9";
              hash = "sha256-GVCpiHip6vxuz6RKRhVk1A7L1I2zuYurDUFloo/xLAs=";
            };
          });
          # Plasma bump (2026-08-01): 25.05-stable ships Plasma 6.2.5, which has
          # a real upstream QML binding-loop bug in PanelConfiguration.qml (a
          # SpinBox implicitWidth loop that fires every time panel-edit mode
          # opens — spams the journal and stalls the compositor while editing
          # widgets). Pull just plasma-desktop + plasma-workspace from
          # nixpkgs-unstable instead of bumping the whole system off 25.05.
          kdePackages = prev.kdePackages // {
            plasma-desktop = final.unstable.kdePackages.plasma-desktop;
            plasma-workspace = final.unstable.kdePackages.plasma-workspace;
          };
        })
      ];

      # Common pkgs with overlays
      pkgs = import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
      };

      # ============================================================
      # Profile Definitions (8 Tool Categories + 2 Desktop Environments)
      # ============================================================
      # Tool profiles are DATA-DRIVEN: source of truth is
      # ./modules/leaves.json (a flat map of profile-name → list of
      # "<category>/<leaf>" strings, with `_comment` ignored). Each leaf
      # path resolves to ./modules/<category>/<leaf>.nix. Adding/removing a
      # leaf is a one-line JSON edit — no Nix code change.
      profileLeaves = nixpkgs.lib.filterAttrs
        (n: _: !(nixpkgs.lib.hasPrefix "_" n))
        (builtins.fromJSON (builtins.readFile ./modules/leaves.json));

      mkProfile = leaves: {
        imports = builtins.map
          (l: ./modules + "/${l}.nix")
          leaves;
      };

      profiles = (builtins.mapAttrs (_: mkProfile) profileLeaves) // {
        # Desktop environment profiles (pick one) — full DE configs, not
        # leaf-shaped, so they bypass the leaves.json pipeline.
        desktop-plasma = ./modules/desktop/plasma.nix;
        desktop-gnome  = ./modules/desktop/gnome.nix;
      };

      # devProfile — DEV USERSPACE buildEnv (Design B). Harvests home.packages from
      # the `dev-space` leaf group (leaves.json) by evaluating those SAME leaf
      # modules through the standalone HM lib with THIS flake's pkgs (overlays:
      # unstable/customPkgs/nur) + inputs — one definition, shared with the pool
      # (DRY). bc_flakes_dev-store/build.sh realises this into the p5 chroot store
      # (never the pool); it is NEVER added to a host profile — reached only inside
      # the `dev` bwrap shell. See a0_tasks/PLAN_dev-store-split.md.
      devProfile = pkgs.buildEnv {
        name = "dev-profile";
        paths = (home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit inputs; };
          modules = [
            profiles.dev-space
            # The rust toolchain (rustc/cargo/subcommands) is a userModule, not a
            # leaf — pull it into dev too (it moves OUT of userModules in the pool
            # flip). node-npm-deps stays in userspace (node kept at login).
            ./modules/rust-cargo-deps.nix
            { home = { username = "diego"; homeDirectory = "/home/diego"; stateVersion = "24.11"; }; }
          ];
        }).config.home.packages ++ (with pkgs; [
          # SELF-COMPLETE shell base: inside the `dev` bwrap shell /nix/store IS the
          # p5 store, so the userspace bash/coreutils (pool paths) are masked — the
          # dev profile must carry its own or `dev` has no usable shell.
          bashInteractive coreutils-full gnugrep gnused gawk findutils which less
          gnutar gzip git openssh cacert starship
        ]);
        pathsToLink = [ "/bin" "/share" "/lib" "/libexec" "/etc" ];
        ignoreCollisions = true;
      };

      # Helper to enable profiles by name
      enableProfiles = profileNames:
        builtins.map (name: profiles.${name}) profileNames;

      # ============================================================
      # Host Presets
      # ============================================================
      # Base tool sets (no DE)
      toolsets = {
        full = [
          "shell-core"
          "dev-languages"
          "build-debug"
          "containers-cloud"
          "security-network"
          "data-science"
          "productivity"
          "media-graphics"
        ];
        cli = [
          "shell-core"
          "dev-languages"
          "build-debug"
          "containers-cloud"
          "security-network"
          "data-science"
        ];
        minimal = [
          "shell-core"
          "dev-languages"
          "build-debug"
        ];
        server = [
          "shell-core"
          "containers-cloud"
          "security-network"
        ];
      };

      # Presets with Desktop Environments
      presets = {
        # Full + Plasma (dark theme, 125% scale, touchpad)
        full-plasma = toolsets.full ++ [ "desktop-plasma" ];
        # Full + GNOME (dark theme, 125% scale, touchpad)
        full-gnome = toolsets.full ++ [ "desktop-gnome" ];
        # CLI-only (no GUI/DE)
        cli = toolsets.cli;
        # Minimal (shell + dev)
        minimal = toolsets.minimal;
        # Server (cloud ops)
        server = toolsets.server;
        # Legacy: full without DE config
        full = toolsets.full;
      };

      # ============================================================
      # Shared base modules (USER tier — dotfiles, configs, activation scripts)
      # These are lightweight and evaluate in ~15 seconds.
      # ============================================================
      userModules = [
        sops-nix.homeManagerModules.sops
        ./modules/sops.nix
        ./claude/claude.nix
        ./modules/common.nix
        ./modules/desktop-session/system-protection.nix
        ./modules/ssh-stale-socket-cleaner.nix
        ./modules/curl-wget-wrapper.nix
        ./modules/home-manager-command-catcher.nix
        ./modules/node-npm-deps.nix
        # rust-cargo-deps moved to the dev profile (devProfile) — rust is a dev
        # tool, reached via `dev`; no longer on the pool/login PATH.
        ./modules/programs/dev-shell.nix   # the `dev` bwrap launcher + bubblewrap (always-on)
        ./modules/programs/flakes-switch-progress-logs   # KDE progress popup for any nix command build.sh wraps (always-on)
        ./modules/programs/hm-auto-update.nix   # poll GHCR for new HM builds, auto build.sh switch (always-on)
        ./modules/programs/disable-baloo.nix   # disable KDE baloo file indexer (CPU/IO hog on this 8GB box)
        ./modules/desktop/store-search.nix     # KRunner search over the CI-built store index (replaces baloo's runner)
        ./modules/programs/disable-thumbnails.nix   # trim Dolphin thumbnail plugins (CPU/IO hog on this 8GB box)
        ./modules/cloud.nix
        ./modules/cloud-network-wg-dns.nix
        ./modules/cloud-network-wg-public.nix
        ./modules/wireguard-wstunnel.nix
        ./modules/front.nix
        ./app_especific   # was orphaned (nothing imported it) — now the sole owner of AI + app leaves
      ];

      # ============================================================
      # Home Manager Configuration Builders
      # ============================================================

      # Full builder (SYS tier — profiles + desktop environments)
      # Evaluates all profiles + Plasma/GNOME → ~10-30 min on constrained hardware
      mkHost = username: homeDir: hostModule: enabledProfiles: profileName: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = userModules ++ [
          # Plasma configuration (only evaluated when desktop-plasma profile is enabled)
          plasma-manager.homeModules.plasma-manager
          hostModule
          {
            home = {
              username = username;
              homeDirectory = homeDir;
              stateVersion = "24.11";
              sessionVariables.HM_PROFILE = profileName;
              sessionVariables.TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";
            };
            imports = enableProfiles enabledProfiles;
          }
        ];
      };

      # User-only builder (USER tier — dotfiles, shell configs, MCP, secrets)
      # No profiles, no desktop env → evaluates in ~15 seconds
      mkHostUser = username: homeDir: hostModule: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = userModules ++ [
          hostModule
          {
            home = {
              username = username;
              homeDirectory = homeDir;
              stateVersion = "24.11";
              sessionVariables.HM_PROFILE = "user";
            };
          }
        ];
      };

      # ============================================================
      # Container Package List (for dockerTools)
      # ============================================================
      containerPackages = with pkgs; [
        # Shell & Core (Profile 1)
        fish bash coreutils findutils gnugrep gnused gawk
        eza bat fd ripgrep fzf zoxide btop ncdu duf tree
        jq yq-go curl wget htop less git gh rsync

        # Dev Languages (Profile 2)
        unstable.rustc unstable.cargo go nodejs_20 python312 gcc clang

        # Build & Debug (Profile 3)
        cmake ninja gnumake gdb shellcheck shfmt delta direnv just

        # Containers & Cloud (Profile 4)
        kubectl kubernetes-helm k9s terraform ansible

        # Security & Network (Profile 5)
        nmap mtr openssh gnupg age openssl

        # Data Science (Profile 6)
        python312Packages.numpy
        python312Packages.pandas
        python312Packages.ipython
        sqlite

        # Essentials for container
        coreutils bashInteractive cacert
        starship tmux vim
      ];

    in
    {
      # ============================================================
      # Home Manager Configurations
      # ============================================================
      homeConfigurations = {
        # ─── USER tier (dotfiles only, ~15 sec eval) ──────────────────
        "diego@user" = mkHostUser "diego" "/home/diego" ./hosts/surface.nix;

        # ─── SYS tier: Surface Pro (with DE, ~10-30 min eval) ─────────
        "diego@surface-plasma" = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-plasma "surface-plasma";
        "diego@surface-gnome"  = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-gnome "surface-gnome";
        "diego@surface"        = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-plasma "surface-plasma";

        # ─── SYS tier: Server/CLI (no DE) ─────────────────────────────
        "diego@server"  = mkHost "diego" "/home/diego" ./hosts/server.nix presets.server "server";
        "diego@cli"     = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.cli "cli";
        "diego@minimal" = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.minimal "minimal";

        # ─── Legacy/fallback ──────────────────────────────────────────
        "diego_nix@surface" = mkHost "diego_nix" "/home/diego_nix" ./hosts/surface.nix presets.full-plasma "surface-plasma";
        "diego" = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-plasma "full-plasma";
      };

      # ============================================================
      # Container Image (Nix-built OCI image)
      # ============================================================
      packages.${system} = {
        # Dev userspace buildEnv — built into the p5 chroot store (not the pool)
        # by bc_flakes_dev-store/build.sh; entered via the `dev` bwrap shell.
        devProfile = devProfile;

        # ── hm-cache-image: LAYERED image of the desktop HM activation closure ──
        # One layer per store path (dockerTools.buildLayeredImage) → `docker pull`
        # skips unchanged layers, so `build.sh switch` fetches only the store
        # paths that actually changed (incremental) instead of re-downloading the
        # whole 6 GB nar. Pushed to GHCR by `ci-build`; consumed by `switch`
        # (nar.zst kept as the fallback). NOT run as a container — the desktop
        # extracts + registers its /nix/store layers into the host store.
        hm-cache-image = pkgs.dockerTools.buildLayeredImage {
          name = "unix-hm-cache";
          tag = "latest";
          maxLayers = 120;
          contents = [ self.homeConfigurations."diego@surface-plasma".activationPackage ];
          config.Labels = {
            "org.opencontainers.image.description" = "Desktop home-manager activation closure as layered store paths (incremental GHCR cache).";
            "org.opencontainers.image.source" = "https://github.com/diegonmarcos/cloud-unix";
            # The activation store path baked into this image. A KB-sized
            # `skopeo inspect` reads this label so `build.sh switch` knows
            # WHICH store path to activate WITHOUT downloading the 6 GB nar
            # artifact first (the artifact was previously the only carrier of
            # this metadata). Enables true incremental-only switching.
            "com.diegonmarcos.activation-path" = "${self.homeConfigurations."diego@surface-plasma".activationPackage}";
          };
        };

        # ── dev-store-cache-image: LAYERED image of the devProfile closure ──
        # Same incremental-GHCR-cache pattern as hm-cache-image, for the heavy
        # dev toolchain (bc_flakes_dev-store/build.sh ci-build pushes it; pull
        # consumes it before falling back to the full nar.zst tarball).
        dev-store-cache-image = pkgs.dockerTools.buildLayeredImage {
          name = "unix-dev-store-cache";
          tag = "latest";
          maxLayers = 120;
          contents = [ devProfile ];
          config.Labels = {
            "org.opencontainers.image.description" = "Dev-store profile (devProfile) as layered store paths (incremental GHCR cache).";
            "org.opencontainers.image.source" = "https://github.com/diegonmarcos/cloud-unix";
            # devProfile store path baked in — same skopeo-inspect metadata
            # pattern as hm-cache-image (consumed by dev-store incremental pull).
            "com.diegonmarcos.activation-path" = "${devProfile}";
          };
        };

        # Main container image
        container = pkgs.dockerTools.buildImage {
          name = "diego-dev";
          tag = "latest";

          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths = containerPackages ++ [
              # Add /bin/sh for compatibility
              (pkgs.runCommand "sh-link" {} ''
                mkdir -p $out/bin
                ln -s ${pkgs.bashInteractive}/bin/bash $out/bin/sh
              '')
              # Add /etc files
              (pkgs.runCommand "etc-files" {} ''
                mkdir -p $out/etc
                echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
                echo "diego:x:1000:1000:Diego:/home/diego:/bin/fish" >> $out/etc/passwd
                echo "root:x:0:" > $out/etc/group
                echo "diego:x:1000:" >> $out/etc/group
              '')
            ];
            pathsToLink = [ "/bin" "/lib" "/share" "/etc" ];
          };

          config = {
            Cmd = [ "${pkgs.fish}/bin/fish" ];
            Env = [
              "TERM=xterm-256color"
              "LANG=en_DK.UTF-8"
              "HOME=/home/diego"
              "USER=diego"
              "PATH=/bin:/usr/bin:/home/diego/.nix-profile/bin"
            ];
            WorkingDir = "/home/diego";
            User = "diego";
          };
        };

        # Minimal container (shell + core tools only)
        container-minimal = pkgs.dockerTools.buildImage {
          name = "diego-dev-minimal";
          tag = "latest";

          copyToRoot = pkgs.buildEnv {
            name = "image-root-minimal";
            paths = with pkgs; [
              fish bash coreutils findutils gnugrep gnused
              eza bat fd ripgrep fzf zoxide btop git gh
              curl wget jq starship tmux vim cacert bashInteractive
              (pkgs.runCommand "sh-link" {} ''
                mkdir -p $out/bin
                ln -s ${pkgs.bashInteractive}/bin/bash $out/bin/sh
              '')
            ];
            pathsToLink = [ "/bin" "/lib" "/share" "/etc" ];
          };

          config = {
            Cmd = [ "${pkgs.fish}/bin/fish" ];
            Env = [
              "TERM=xterm-256color"
              "HOME=/home/diego"
              "PATH=/bin"
            ];
            WorkingDir = "/home/diego";
          };
        };

        # ── nixos-hm: layered image for GHCR (used by ca_containers_user) ──
        container-nixos-hm = pkgs.dockerTools.buildLayeredImage {
          name = "ghcr.io/diegonmarcos/user-dev-x86-nixos-nix-hm";
          tag = "latest";
          maxLayers = 125;

          contents = containerPackages ++ [
            (pkgs.runCommand "base-files" {} ''
              mkdir -p $out/bin $out/etc $out/home/diego/git $out/tmp
              ln -s ${pkgs.bashInteractive}/bin/bash $out/bin/sh
              echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
              echo "diego:x:1000:1000:Diego:/home/diego:${pkgs.fish}/bin/fish" >> $out/etc/passwd
              echo "root:x:0:" > $out/etc/group
              echo "diego:x:1000:" >> $out/etc/group
              echo "user-dev-x86-nixos-nix-hm" > $out/etc/hostname
            '')
            # All repos (self-contained image) — fetched by Nix, baked into layer
            (let
              repos = {
                unix       = builtins.fetchGit { url = "https://github.com/diegonmarcos/cloud-unix.git";       ref = "main"; shallow = true; };
                cloud      = builtins.fetchGit { url = "https://github.com/diegonmarcos/cloud-infra.git";      ref = "main"; shallow = true; };
                cloud-data = builtins.fetchGit { url = "https://github.com/diegonmarcos/cloud-data.git"; ref = "main"; shallow = true; };
                front      = builtins.fetchGit { url = "https://github.com/diegonmarcos/diegonmarcos.github.io.git"; ref = "main"; shallow = true; };
                front-data = builtins.fetchGit { url = "https://github.com/diegonmarcos/front-data.git"; ref = "main"; shallow = true; };
              };
            in pkgs.runCommand "bake-repos" {} ''
              mkdir -p $out/home/diego/git
              ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: src:
                "cp -r ${src} $out/home/diego/git/${name}"
              ) repos))}
            '')
          ];

          config = {
            Cmd = [ "${pkgs.fish}/bin/fish" ];
            Env = [
              "TERM=xterm-256color"
              "LANG=en_DK.UTF-8"
              "HOME=/home/diego"
              "USER=diego"
              "SHELL=${pkgs.fish}/bin/fish"
              "PATH=/bin:/home/diego/.nix-profile/bin:/nix/var/nix/profiles/default/bin"
            ];
            WorkingDir = "/home/diego";
            User = "diego";
            Labels = {
              "org.opencontainers.image.title" = "user-dev-x86-nixos-nix-hm";
              "org.opencontainers.image.description" = "Pure Nix container — Home-Manager cli profile (dockerTools.buildLayeredImage)";
              "org.opencontainers.image.source" = "https://github.com/diegonmarcos/cloud-unix";
              "diego.image.variant" = "nixos-hm";
              "diego.image.flake.path" = "ba_flakes_desktop/src/";
              "diego.image.flake.config" = "diego@cli";
              "diego.image.ghcr" = "ghcr.io/diegonmarcos/user-dev-x86-nixos-nix-hm";
              "diego.image.profiles" = "cli,gui,tty";
              "diego.image.runner" = "dtk.sh containers nixos-hm {cli|gui|tty}";
              "diego.image.packages.shell" = "fish starship eza bat fd rg fzf jq";
              "diego.image.packages.lang" = "rustup go node python gcc clang";
              "diego.image.packages.cloud" = "kubectl helm terraform ansible";
            };
          };
        };

        # Default package
        default = self.packages.${system}.container;
      };

      # ============================================================
      # Development Shell
      # ============================================================
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          home-manager.packages.${system}.default
          pkgs.nil           # Nix LSP
          pkgs.nixpkgs-fmt
          pkgs.podman
          pkgs.skopeo
        ];
        shellHook = ''
          echo "Diego's Nix Dev Environment"
          echo "Commands:"
          echo "  home-manager switch --flake .#diego@surface  # Apply config"
          echo "  nix build .#container                        # Build container"
          echo "  podman load < result                         # Load container"
        '';
      };
    };
}
# cache-bust 1774350227
