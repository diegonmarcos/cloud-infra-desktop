{
  description = "Diego's Home Manager - Termux / nix-on-droid (aarch64-linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, ... }@inputs:
    let
      system = "aarch64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

    in
    {
      homeConfigurations = {
        "nix-on-droid" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit inputs; };
          modules = [
            sops-nix.homeManagerModules.sops
            ./modules/common.nix
            ./modules/packages.nix
            {
              home = {
                username = "nix-on-droid";
                homeDirectory = "/data/data/com.termux.nix/files/home";
                stateVersion = "24.11";
              };
            }
          ];
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          home-manager.packages.${system}.default
          pkgs.nil
        ];
        shellHook = ''
          echo "Termux Nix Home Manager"
          echo "  home-manager switch --flake .#nix-on-droid"
        '';
      };
    };
}
