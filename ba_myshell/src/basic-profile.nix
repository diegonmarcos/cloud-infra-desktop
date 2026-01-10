{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Isolation
    bubblewrap       # Sandbox for real HOME isolation

    # Shell Profile tools
    fish             # Friendly Interactive Shell (default)
    zsh              # Z Shell with powerful features
    starship         # Cross-shell prompt
    eza              # Modern ls replacement
    bat              # Cat with syntax highlighting
    fzf              # Fuzzy finder
    zoxide           # Smart cd

    # Minimum Profile tools
    git              # Version control
    vim              # Text editor
    ripgrep          # Fast grep (rg)
    fd               # Fast find
    curl             # HTTP client
    wget             # Download tool
    jq               # JSON processor
    yazi             # Terminal file manager

    # Basic Profile additions - Runtimes & cloud tools
    nodejs           # Node.js runtime + npm
    python3          # Python interpreter + pip
    rclone           # Cloud storage sync
    google-cloud-sdk # Google Cloud CLI (gcloud)
    wireguard-tools  # WireGuard VPN (wg, wg-quick)
  ];

  shellHook = ''
    # Welcome message is printed by launcher after isolation setup
  '';
}
