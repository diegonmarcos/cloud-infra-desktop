# Services: shared tools & data integration
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # SHARED TOOLS & DATA INTEGRATION
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # @shared/ structure:
  #   tools/      - CLI tools (base, dev, data, devops) + scripts
  #   configs/    - Shared configurations (vpn, app configs)
  #   data/       - Persistent data (cache, containers, vm, fonts, themes)
  #   waydroid/   - Android
  #   mnt/        - External drive mount points
  #

  environment.sessionVariables = {
    # Shared caches (inside data/)
    # CARGO_HOME: owned by home-manager (rust-cargo-deps.nix)
    # GOPATH: owned by home-manager (2-dev-languages.nix)
    npm_config_cache = "/mnt/shared/data/cache/npm";
    PIP_CACHE_DIR = "/mnt/shared/data/cache/pip";

    # PATH for /mnt/shared/tools is managed by home-manager (home.sessionPath)
    # so it is centralized with all other user PATH entries there
  };
}
