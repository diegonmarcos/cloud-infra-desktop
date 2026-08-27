{
  description = "my-konsole - Ultra-Minimal USB Recovery System";

  inputs = {
    # nixos-25.05 base → stock kernel 6.12.x, a prebuilt cache.nixos.org hit (no
    # from-source compile). The old linux-surface 6.19.8 pin is gone, so the
    # blake2b_generic-builtin initrd abort is moot (it's a loadable module on the
    # stock kernel). btrfs is still kept out of the initrd for slimness — see
    # configuration.nix's initrd block; btrfs recovery is a post-boot task.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # ISO/image generation
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
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
          # Stock nixpkgs kernel (prebuilt cache hit) — NO linux-surface compile.
          # Surface Type Cover keyboard works via mainline SAM modules (see configuration.nix boot.kernelModules).
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
        ./configuration.nix
        ./iso.nix
      ];
    };
  };
}
