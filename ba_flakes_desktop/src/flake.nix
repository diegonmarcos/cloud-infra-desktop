{
  description = "Diego's Home Manager - Standalone Multi-Distro Setup with Container Support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
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
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, nur, sops-nix, plasma-manager, ... }@inputs:
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
        ./modules/common.nix
        ./modules/desktop-session/system-protection.nix
        ./modules/ssh-stale-socket-cleaner.nix
        ./modules/curl-wget-wrapper.nix
        ./modules/node-npm-deps.nix
        ./modules/rust-cargo-deps.nix
        ./modules/cloud.nix
        ./modules/cloud-network-wg-dns.nix
        ./modules/front.nix
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
                unix       = builtins.fetchGit { url = "https://github.com/diegonmarcos/unix.git";       ref = "main"; shallow = true; };
                cloud      = builtins.fetchGit { url = "https://github.com/diegonmarcos/cloud.git";      ref = "main"; shallow = true; };
                cloud-data = builtins.fetchGit { url = "https://github.com/diegonmarcos/cloud-data.git"; ref = "main"; shallow = true; };
                front      = builtins.fetchGit { url = "https://github.com/diegonmarcos/diegonmarcos.github.io.git"; ref = "main"; shallow = true; };
                front-data = builtins.fetchGit { url = "https://github.com/diegonmarcos/front-data.git"; ref = "main"; shallow = true; };
                tools      = builtins.fetchGit { url = "https://github.com/diegonmarcos/tools.git";      ref = "main"; shallow = true; };
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
              "org.opencontainers.image.source" = "https://github.com/diegonmarcos/unix";
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
