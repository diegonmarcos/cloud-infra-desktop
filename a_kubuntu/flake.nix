{
  description = "Diego's Home Manager - Standalone Multi-Distro Setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nur.url = "github:nix-community/NUR";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, nur, ... }@inputs:
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

      # Helper to enable profiles by name
      enableProfiles = profiles:
        builtins.map (p: ./modules/profiles/${p}.nix) profiles;

      # Build a host configuration with selected profiles
      mkHost = username: homeDir: hostModule: enabledProfiles: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          ./modules/common.nix
          hostModule
          {
            home = {
              username = username;
              homeDirectory = homeDir;
              stateVersion = "24.11";
            };
            imports = enableProfiles enabledProfiles;
          }
        ];
      };

    in
    {
      homeConfigurations = {
        # diego_nix user - Full Nix-centric setup (ALL profiles)
        "diego_nix@surface" = mkHost "diego_nix" "/home/diego_nix" ./hosts/surface.nix [
          "base"
          "dev-langs"
          "dev-tools"
          "security"
          "productivity"
          "media"
          "cloud"
          "data-science"
        ];

        # Original diego user configurations (for reference)
        "diego@surface" = mkHost "diego" "/home/diego" ./hosts/surface.nix [
          "base"
          "dev-langs"
          "dev-tools"
          "security"
          "productivity"
          "cloud"
          "data-science"
        ];

        "diego@desktop" = mkHost "diego" "/home/diego" ./hosts/desktop.nix [
          "base"
          "dev-langs"
          "dev-tools"
          "media"
          "productivity"
          "cloud"
        ];

        "diego@server" = mkHost "diego" "/home/diego" ./hosts/server.nix [
          "base"
          "cloud"
        ];

        # Generic fallback
        "diego" = mkHost "diego" "/home/diego" ./hosts/surface.nix [
          "base"
          "dev-langs"
          "dev-tools"
          "security"
          "productivity"
          "media"
          "cloud"
          "data-science"
        ];
      };

      # Development shell for working on this config
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          home-manager
          nil  # Nix LSP
          nixpkgs-fmt
        ];
      };
    };
}
