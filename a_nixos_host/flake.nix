{
  description = "NixOS Surface Pro 8 - Minimal + User Agnostic";

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
  in {
    # Main NixOS configuration for Surface Pro 8
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        # Surface Pro hardware support (linux-surface kernel, firmware)
        nixos-hardware.nixosModules.microsoft-surface-pro-intel

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
          ./configuration.nix
          ./hardware-configuration.nix
        ];
        format = "raw-efi";
      };

      # VM for quick testing (no Surface hardware needed)
      vm = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          ./configuration.nix
        ];
        format = "vm";
      };
    };
  };
}
