{
  description = "NixOS Surface Pro 8 - Minimal + User Agnostic";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Unstable for newer KDE packages (clipboard fixes in KF6 6.22+)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    sddm-sugar-candy-nix = {
      url = "github:Zhaith-Izaliel/sddm-sugar-candy-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, nixos-generators, home-manager, plasma-manager, sddm-sugar-candy-nix, ... }:
  let
    system = "x86_64-linux";

    # Overlay to use newer KDE Connect from unstable (fixes clipboard freeze)
    kdeUnstableOverlay = final: prev: {
      kdePackages = prev.kdePackages // {
        kdeconnect-kde = nixpkgs-unstable.legacyPackages.${system}.kdePackages.kdeconnect-kde;
      };
    };
  in {
    # Main NixOS configuration for Surface Pro 8
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit plasma-manager; };
      modules = [
        # KDE Connect from unstable (clipboard freeze fix)
        { nixpkgs.overlays = [ kdeUnstableOverlay ]; }
        # Surface Pro hardware support (linux-surface kernel, firmware)
        nixos-hardware.nixosModules.microsoft-surface-pro-intel

        # Home Manager integration
        home-manager.nixosModules.home-manager

        # SDDM Sugar Candy theme
        sddm-sugar-candy-nix.nixosModules.default

        # Main configuration
        ./configuration.nix

        # Custom SDDM sessions
        ./sessions.nix

        # Hardware-specific
        ./hardware-configuration.nix
      ];
    };

    # Build outputs
    # NOTE: Image generators define their own filesystems, so we DON'T include
    # hardware-configuration.nix (which has tmpfs root for impermanence)
    packages.${system} = {
      # OCI/Docker image for deployment
      oci-image = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./configuration.nix
        ];
        format = "docker";
      };

      # Raw disk image for installation
      raw = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./configuration.nix
          # Disk size: 48GB to accommodate closure (~15GB) + overhead + working space
          { config.virtualisation.diskSize = 48 * 1024; }
        ];
        format = "raw-efi";
      };

      # ISO for live boot/installation (uses squashfs, more reliable)
      iso = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./configuration.nix
          # ISO-specific overrides
          ({ lib, pkgs, ... }: {
            # ISO uses wpa_supplicant instead of NetworkManager for live env
            networking.networkmanager.enable = lib.mkForce false;
            # Ensure our users have working passwords (ISO profile can interfere)
            users.users.diego.initialPassword = lib.mkForce "1234567890";
            users.users.guest.initialPassword = lib.mkForce "1234567890";
            # Also set password for the ISO's default nixos user
            users.users.nixos.initialPassword = lib.mkForce "1234567890";
          })
        ];
        format = "install-iso";
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
