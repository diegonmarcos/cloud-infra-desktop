{
  description = "NixOS Surface Slim - Ultra-Minimal USB Recovery System";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Surface Pro hardware support (linux-surface kernel, iptsd, firmware)
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # ISO/image generation
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, nixos-generators, ... }:
  let
    system = "x86_64-linux";
  in {
    # ═══════════════════════════════════════════════════════════════════════════
    # ISO IMAGE (Main output for Ventoy USB)
    # ═══════════════════════════════════════════════════════════════════════════
    packages.${system} = {
      # Live ISO for Ventoy
      iso = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          # CRITICAL: Surface hardware support (linux-surface kernel + iptsd)
          nixos-hardware.nixosModules.microsoft-surface-pro-intel

          ./configuration.nix
          ./iso.nix
        ];
        format = "iso";
      };

      # VM for testing (no Surface hardware needed)
      vm = nixos-generators.nixosGenerate {
        inherit system;
        modules = [ ./configuration.nix ];
        format = "vm";
      };
    };

    # Default package is ISO
    packages.${system}.default = self.packages.${system}.iso;

    # ═══════════════════════════════════════════════════════════════════════════
    # NIXOS CONFIGURATION (for nixos-rebuild if needed)
    # ═══════════════════════════════════════════════════════════════════════════
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
