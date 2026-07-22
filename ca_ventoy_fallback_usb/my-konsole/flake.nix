{
  description = "my-konsole - Ultra-Minimal USB Recovery System";

  inputs = {
    # nixos-25.05 pinned (not 24.11) as the general base. NOTE: 25.05 alone does
    # NOT fix the blake2b_generic-builtin initrd abort — GHA run 29081577942
    # failed on 25.05 with exactly that. The real fix is keeping btrfs OUT of
    # boot.initrd.supportedFilesystems (see configuration.nix's initrd block):
    # the initrd never mounts btrfs, so its blake2b_generic checksum dep (builtin
    # =y on the linux-surface 6.19.8 kernel) must never enter the modules-shrunk
    # modprobe walk. btrfs recovery stays available post-boot via the stage-2
    # module + btrfs-progs.
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
