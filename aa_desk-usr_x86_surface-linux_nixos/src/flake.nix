{
  description = "NixOS Surface Pro 8 - System Only (no home-manager)";

  # Add the linux-surface community cachix as an extra substituter so the
  # linux-surface kernel (used via hardware.microsoft-surface.kernelVersion in
  # modules/hardware_surface.nix) can be FETCHED instead of built locally.
  # Added 2026-05-15 after the pool-incident reinstall — a fresh install spent
  # ~30 min compiling linux-6.15.9 because cache.nixos.org does not pre-build
  # the linux-surface variant.
  nixConfig = {
    extra-substituters = [ "https://linux-surface.cachix.org" ];
    extra-trusted-public-keys = [
      "linux-surface.cachix.org-1:f+M1d2Zq+TfvrcL3vrAJL3Pc4U5GbU+s5SCV5fAR4ow="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Unstable for newer KDE packages (clipboard fixes in KF6 6.22+)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NUR — for ataraxiasjel.waydroid-script, the reproducibly-packaged
    # casualsnek waydroid_script (libhoudini ARM translation). Surface Pro 8 is
    # x86_64; the cloud-superapp APK is arm64-v8a only, so Waydroid needs an ARM
    # bridge to run it. See modules/configuration_containers.nix.
    nur.url = "github:nix-community/NUR";

    # NOTE: fido2-vault-broker is NOT a flake input — nix 2.24 cannot lock
    # or re-fetch relative-path flake inputs inside a git flake (every
    # `nix flake update`/eval died on it, 2026-06-11/12). Its NixOS module
    # + package are composed by PLAIN PATH IMPORT instead:
    # module:  ../../da_fido2-vault-broker/src/nix/module.nix  (modules list)
    # package: ../../da_fido2-vault-broker/src/nix/package.nix (set in
    #          ./modules/configuration_fido2-vault-broker.nix via callPackage)
    # Revisit as a proper input when nix >= 2.26 (native relative-path flakes).

    # NOTE: home-manager is NOT here - it's managed separately in cb_user_diego_nix
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, nixos-generators, nur, ... }:
  let
    system = "x86_64-linux";

    # NOTE: KDE Connect unstable overlay removed - caused Qt version mismatch
    # (unstable kdeconnect 25.12.1 needs Qt 6.10, but Plasma 6.2.5 uses Qt 6.8)
    # Clipboard sync is handled by kdeconnect-clipboard-sync systemd service instead
  in {
    # Main NixOS configuration for Surface Pro 8
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      inherit system;
      # pkgsUnstable: for packages whose toolchain outgrew 24.11 — e.g.
      # fido2-vault-broker's cargo deps need edition-2024 (cargo ≥ 1.85, not
      # in stable 24.11). Scoped per-package via specialArgs, never a global
      # overlay (see the KDE Connect Qt-mismatch note above for why).
      specialArgs = {
        pkgsUnstable = import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
        # NUR repo holding waydroid-script (libhoudini ARM translation).
        # Scoped per-module via specialArgs, never a global overlay.
        nurpkgs = nur.legacyPackages.${system}.repos.ataraxiasjel;
      };
      modules = [
        # Surface Pro hardware support (linux-surface kernel, firmware)
        nixos-hardware.nixosModules.microsoft-surface-pro-intel

        # Main configuration (modular)
        ./modules/configuration.nix

        # Custom SDDM sessions
        ./modules/sessions.nix

        # Hardware-specific
        ./modules/hardware.nix

        # FIDO2 vault broker — self-contained NixOS module from the daemon repo,
        # composed by plain path import (see inputs NOTE above).
        # Brings: boot.kernelModules += "uhid", /dev/uhid udev rule, `uhid` +
        # `tss` group membership for diego, security.tpm2 for /dev/tpmrm0.
        ../../da_fido2-vault-broker/src/nix/module.nix
        ./modules/configuration_fido2-vault-broker.nix
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
          ./modules/configuration.nix
        ];
        format = "docker";
      };

      # Raw disk image for installation
      raw = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./modules/configuration.nix
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
          ./modules/configuration.nix
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
          ./modules/configuration.nix
        ];
        format = "vm";
      };
    };
  };
}
