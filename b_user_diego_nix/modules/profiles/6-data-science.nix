# Profile 6: Data Science & Databases
# ML/AI, analysis, storage
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
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

    # Jupyter
    jupyter
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
    mongodb

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

  # Install AI CLI tools via npm
  home.activation.installAiTools = lib.hm.dag.entryAfter ["writeBoundary"] ''
    if command -v npm &>/dev/null; then
      $DRY_RUN_CMD npm install -g @anthropic-ai/claude-code 2>/dev/null || true
    fi
  '';

  # Python environment
  home.sessionVariables = {
    PYTHONPATH = "$HOME/.local/lib/python3.12/site-packages:$PYTHONPATH";
    JUPYTER_CONFIG_DIR = "$HOME/.config/jupyter";
  };
}
