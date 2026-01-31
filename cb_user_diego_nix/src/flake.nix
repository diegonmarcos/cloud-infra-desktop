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
      profiles = {
        # Tool profiles
        shell-core        = ./modules/profiles/1-shell-core.nix;
        dev-languages     = ./modules/profiles/2-dev-languages.nix;
        build-debug       = ./modules/profiles/3-build-debug.nix;
        containers-cloud  = ./modules/profiles/4-containers-cloud.nix;
        security-network  = ./modules/profiles/5-security-network.nix;
        data-science      = ./modules/profiles/6-data-science.nix;
        productivity      = ./modules/profiles/7-productivity.nix;
        media-graphics    = ./modules/profiles/8-media-graphics.nix;
        # Desktop environment profiles (pick one)
        desktop-plasma    = ./modules/desktop/plasma.nix;
        desktop-gnome     = ./modules/desktop/gnome.nix;
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
      # Home Manager Configuration Builder
      # ============================================================
      mkHost = username: homeDir: hostModule: enabledProfiles: profileName: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          # Secrets management
          sops-nix.homeManagerModules.sops
          ./modules/sops.nix

          # Plasma configuration (for desktop-plasma profile)
          plasma-manager.homeManagerModules.plasma-manager

          ./modules/common.nix
          hostModule
          {
            home = {
              username = username;
              homeDirectory = homeDir;
              stateVersion = "24.11";
              sessionVariables.HM_PROFILE = profileName;
            };
            imports = enableProfiles enabledProfiles;
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
        rustup go nodejs_20 python312 gcc clang

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
        # ─── Surface Pro (with DE) ────────────────────────────────────
        "diego@surface-plasma" = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-plasma "surface-plasma";
        "diego@surface-gnome"  = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-gnome "surface-gnome";
        "diego@surface"        = mkHost "diego" "/home/diego" ./hosts/surface.nix presets.full-plasma "surface-plasma";

        # ─── Desktop (with DE) ────────────────────────────────────────
        "diego@desktop-plasma" = mkHost "diego" "/home/diego" ./hosts/desktop.nix presets.full-plasma "desktop-plasma";
        "diego@desktop-gnome"  = mkHost "diego" "/home/diego" ./hosts/desktop.nix presets.full-gnome "desktop-gnome";
        "diego@desktop"        = mkHost "diego" "/home/diego" ./hosts/desktop.nix presets.full-plasma "desktop-plasma";

        # ─── Server/CLI (no DE) ───────────────────────────────────────
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
              "LANG=en_US.UTF-8"
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
