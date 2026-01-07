{
  description = "NixOS Surface Slim - Minimal USB Recovery System";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, nixos-generators, ... }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # ISO image for USB boot
    packages.${system} = {
      # Main ISO output
      iso = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./configuration.nix
          ./iso.nix
        ];
        format = "iso";
      };

      # Raw disk image (alternative)
      raw = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./configuration.nix
        ];
        format = "raw-efi";
      };

      # VM for testing
      vm = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          ./configuration.nix
        ];
        format = "vm";
      };
    };

    # Default package is ISO
    packages.${system}.default = self.packages.${system}.iso;

    # NixOS configuration (for direct nixos-rebuild)
    nixosConfigurations.surface-slim = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixos-hardware.nixosModules.microsoft-surface-pro-intel
        ./configuration.nix
        ./iso.nix
      ];
    };
  };
}
