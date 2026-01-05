{
  description = "NixOS Surface Pro Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }: {
    # Raw disk image for installation
    packages.x86_64-linux.raw = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
      format = "raw-efi";
    };

    # QCOW2 for VM testing
    packages.x86_64-linux.qcow = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
      format = "qcow";
    };

    # ISO for USB boot
    packages.x86_64-linux.iso = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
      format = "iso";
    };

    # VM for quick testing
    packages.x86_64-linux.vm = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
      format = "vm";
    };

    # Default NixOS configuration
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
    };
  };
}
