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
    # NOTE: home-manager overrides CARGO_HOME/GOPATH to ~/.cargo / ~/go
    # These system-level vars apply to root and system services only
    CARGO_HOME = "/mnt/shared/data/cache/cargo";
    GOPATH = "/mnt/shared/data/cache/go";
    npm_config_cache = "/mnt/shared/data/cache/npm";
    PIP_CACHE_DIR = "/mnt/shared/data/cache/pip";

    # PATH for /mnt/shared/tools is managed by home-manager (home.sessionPath)
    # so it is centralized with all other user PATH entries there
  };
}
