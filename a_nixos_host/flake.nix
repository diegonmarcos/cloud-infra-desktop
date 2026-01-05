{
  description = "NixOS Surface Pro 8 - Full Impermanence";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    impermanence.url = "github:nix-community/impermanence";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, impermanence, nixos-generators, ... }:
  let
    system = "x86_64-linux";
  in {
    # Main NixOS configuration for Surface Pro 8
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        # Surface Pro hardware support
        nixos-hardware.nixosModules.microsoft-surface-pro-intel

        # Impermanence module
        impermanence.nixosModules.impermanence

        # Main configuration
        ./configuration.nix

        # Hardware-specific
        ./hardware-configuration.nix
      ];
    };

    # Build outputs
    packages.${system} = {
      # OCI/Docker image for deployment
      oci-image = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          impermanence.nixosModules.impermanence
          ./configuration.nix
          ./hardware-configuration.nix
        ];
        format = "docker";
      };

      # Raw disk image for testing
      raw = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          impermanence.nixosModules.impermanence
          ./configuration.nix
          ./hardware-configuration.nix
        ];
        format = "raw-efi";
      };

      # VM for quick testing
      vm = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          impermanence.nixosModules.impermanence
          ./configuration.nix
        ];
        format = "vm";
      };
    };
  };
}
