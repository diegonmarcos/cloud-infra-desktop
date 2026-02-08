# Profile 6: Data Science & Databases
# ML/AI, analysis, storage
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # AI CLI tools (custom packages)
    customPkgs.claude-code
    customPkgs.gemini-cli

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
