# Profile 6: Data Science & Databases
# ML/AI, analysis, storage
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # AI CLI tools
    # claude-code: direct Bun binary from Anthropic GCS + patchelf (common.nix activation)
    customPkgs.gemini-cli
    # customPkgs.cloud-infra-mcp  # TODO: define this custom package

    # Claude wrappers
    (pkgs.writeShellScriptBin "claude-termux" ''
      export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=1024"
      exec claude "$@"
    '')
    (pkgs.writeShellScriptBin "claude-malloc" ''
      export MALLOC_ARENA_MAX=2
      export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=2048"
      export CLAUDE_TMP="$HOME/tmp/claude"
      mkdir -p "$CLAUDE_TMP"
      export TMPDIR="$CLAUDE_TMP"
      exec claude "$@"
    '')
    (pkgs.writeShellScriptBin "claude-rescue" ''
      echo "Claude Rescue — fallback chain"
      export ANTHROPIC_API_KEY="''${ANTHROPIC_API_KEY:-}"
      export TERM="''${TERM:-xterm-256color}"
      # 1) Podman
      if command -v podman >/dev/null 2>&1; then
        echo "[1/4] Trying podman..."
        timeout 60 podman run --rm -it \
          --name claude-rescue \
          -v "$HOME:/host-home:ro" \
          -e ANTHROPIC_API_KEY -e TERM \
          --user root \
          node:22-slim \
          sh -c 'npm install -g @anthropic-ai/claude-code 2>/dev/null && claude "$@"' -- "$@" \
          && exit 0
        echo "[1/4] podman failed, trying next..."
      fi
      # 2) npx
      if command -v npx >/dev/null 2>&1; then
        echo "[2/4] Trying npx..."
        npx -y @anthropic-ai/claude-code "$@" && exit 0
        echo "[2/4] npx failed, trying next..."
      fi
      # 3) Nix shell
      if command -v nix >/dev/null 2>&1; then
        echo "[3/4] Trying nix shell..."
        timeout 120 nix shell nixpkgs#nodejs_22 --command sh -c \
          'npx -y @anthropic-ai/claude-code "$@"' -- "$@" \
          && exit 0
        echo "[3/4] nix shell failed, trying next..."
      fi
      # 4) Raw node
      if command -v node >/dev/null 2>&1; then
        echo "[4/4] Trying raw node bootstrap..."
        _tmp=$(mktemp -d)
        cd "$_tmp" && npm init -y >/dev/null 2>&1 && npm install @anthropic-ai/claude-code >/dev/null 2>&1
        ./node_modules/.bin/claude "$@" && exit 0
      fi
      echo "ALL METHODS FAILED"
      exit 1
    '')

    # Python data science core
    python312Packages.numpy
    python312Packages.pandas
    python312Packages.scipy
    python312Packages.matplotlib
    python312Packages.seaborn
    python312Packages.plotly

    # Machine learning
    python312Packages.scikit-learn
    python312Packages.torch
    python312Packages.torchvision

    # Jupyter - DISABLED: causes collisions with individual python packages
    # jupyter  # creates python3-env that collides with individual packages
    python312Packages.jupyterlab
    python312Packages.notebook
    python312Packages.ipython

    # Data processing
    python312Packages.polars
    python312Packages.dask
    python312Packages.pyarrow

    # Databases
    sqlite
    postgresql
    mysql80
    redis
    # mongodb    # DISABLED: builds from source (~2-3 hours!)

    # Database CLIs
    pgcli
    mycli
    litecli

    # Visualization
    python312Packages.bokeh

    # Statistics (R)
    R
    rPackages.ggplot2
    rPackages.dplyr
    rPackages.tidyr

    # Scientific tools
    python312Packages.sympy
    octave

    # Web scraping
    python312Packages.beautifulsoup4
    python312Packages.scrapy

    # API clients
    python312Packages.requests
    python312Packages.httpx

    # Data validation
    python312Packages.pydantic
  ];

  # Python environment
  home.sessionVariables = {
    PYTHONPATH = "$HOME/.local/lib/python3.12/site-packages:$PYTHONPATH";
    JUPYTER_CONFIG_DIR = "$HOME/.config/jupyter";
  };
}
