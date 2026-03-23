# Services: Windmill, shared tools & data integration
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # WINDMILL - Workflow Orchestrator
  # ═══════════════════════════════════════════════════════════════════════════
  # Web UI: http://localhost:8000
  # Use for: NixOS updates, home-manager updates, system maintenance workflows

  services.windmill = {
    enable = true;
    serverPort = 8000;
    lspPort = 3001;

    # Local PostgreSQL database (auto-managed)
    database = {
      createLocally = true;
      name = "windmill";
      user = "windmill";
    };

    # Base URL for webhooks and external access
    baseUrl = "http://localhost:8000";

    logLevel = "info";
  };

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
    CARGO_HOME = "/mnt/shared/data/cache/cargo";
    GOPATH = "/mnt/shared/data/cache/go";
    npm_config_cache = "/mnt/shared/data/cache/npm";
    PIP_CACHE_DIR = "/mnt/shared/data/cache/pip";

    # Tools bin directories in PATH
    PATH = [
      "/mnt/shared/tools/base/bin"
      "/mnt/shared/tools/dev/bin"
      "/mnt/shared/tools/data/bin"
      "/mnt/shared/tools/devops/bin"
      "/mnt/shared/tools/scripts"
    ];
  };
}
