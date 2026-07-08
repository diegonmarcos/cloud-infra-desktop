{
  description = "my-konsole - Ultra-Minimal USB Recovery System";

  inputs = {
    # 25.05 (not 24.11): 24.11's initrd modules-shrunk step runs modprobe and
    # aborts when a btrfs-checksum dep (blake2b_generic) is builtin rather than
    # a loadable .ko — which is the case on the linux-surface 6.19.8 kernel
    # pulled via nixos-hardware master. 25.05's shrink tolerates builtin modules.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

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

      # Default package is ISO — must live inside this single attrset:
      # `packages.${system}` uses a dynamic (interpolated) key, and Nix
      # cannot merge two `packages.${system}...` definitions the way it
      # merges static-key paths (→ "dynamic attribute already defined").
      default = self.packages.${system}.iso;
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # NIXOS CONFIGURATION (for nixos-rebuild if needed)
    # ═══════════════════════════════════════════════════════════════════════════
    nixosConfigurations.my-konsole = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixos-hardware.nixosModules.microsoft-surface-pro-intel
        ./configuration.nix
        ./iso.nix
      ];
    };
  };
}
