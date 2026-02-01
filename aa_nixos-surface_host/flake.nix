{
  description = "NixOS Surface Pro 8 - System Only (no home-manager)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Unstable for newer KDE packages (clipboard fixes in KF6 6.22+)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NOTE: home-manager is NOT here - it's managed separately in cb_user_diego_nix
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, nixos-generators, ... }:
  let
    system = "x86_64-linux";

    # NOTE: KDE Connect unstable overlay removed - caused Qt version mismatch
    # (unstable kdeconnect 25.12.1 needs Qt 6.10, but Plasma 6.2.5 uses Qt 6.8)
    # Clipboard sync is handled by kdeconnect-clipboard-sync systemd service instead
  in {
    # Main NixOS configuration for Surface Pro 8
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        # Surface Pro hardware support (linux-surface kernel, firmware)
        nixos-hardware.nixosModules.microsoft-surface-pro-intel

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
