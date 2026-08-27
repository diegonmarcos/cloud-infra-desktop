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

    # NUR input (ataraxiasjel.waydroid-script / libhoudini) REMOVED 2026-07-01 — waydroid disabled entirely.

    # NOTE: fido2-vault-broker is NOT a flake input — nix 2.24 cannot lock
    # or re-fetch relative-path flake inputs inside a git flake (every
    # `nix flake update`/eval died on it, 2026-06-11/12). Its NixOS module
    # + package are composed by PLAIN PATH IMPORT instead:
    # module:  ../../db_fido2-vault-broker/src/nix/module.nix  (modules list)
    # package: ../../db_fido2-vault-broker/src/nix/package.nix (set in
    #          ./modules/configuration_fido2-vault-broker.nix via callPackage)
    # Revisit as a proper input when nix >= 2.26 (native relative-path flakes).

    # NOTE: home-manager is NOT here - it's managed separately in cb_user_diego_nix
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, nixos-generators, ... }:
  let
    system = "x86_64-linux";

    # Plain nixpkgs (not nixosSystem's internal one) — needed at the flake's
    # top level for packages.${system}.system-cache-image (dockerTools).
    pkgs = import nixpkgs { inherit system; };

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
        ../../db_fido2-vault-broker/src/nix/module.nix
        ./modules/configuration_fido2-vault-broker.nix

        # Waydroid sensors HAL UNWIRED 2026-07-01 — waydroid disabled entirely.
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

      # ── system-cache-image: LAYERED image of the NixOS system closure ──
      # One layer per store path (dockerTools.buildLayeredImage) → `docker
      # pull` skips unchanged layers, so `build.sh pull` fetches only the
      # store paths that actually changed (incremental) instead of
      # re-downloading the whole multi-GB nar every time. Pushed to GHCR by
      # the CI export step (GHCR_PUSH=1); consumed by `pull_remote` (the
      # nar.zst path is kept as the fallback). Mirrors
      # ba_flakes_desktop/src/flake.nix's hm-cache-image exactly. NOT run
      # as a container — the desktop extracts + registers the layers into
      # the real host /nix/store.
      system-cache-image = pkgs.dockerTools.buildLayeredImage {
        name = "unix-system-cache";
        tag = "latest";
        maxLayers = 120;
        contents = [ self.nixosConfigurations.surface.config.system.build.toplevel ];
        config.Labels = {
          "org.opencontainers.image.description" = "Desktop NixOS system closure as layered store paths (incremental GHCR cache).";
          "org.opencontainers.image.source" = "https://github.com/diegonmarcos/cloud-unix";
        };
      };
    };
  };
}
