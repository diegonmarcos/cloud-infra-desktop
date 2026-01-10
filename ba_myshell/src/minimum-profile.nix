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

    # Minimum Profile additions - Essential development tools
    git              # Version control
    vim              # Text editor
    ripgrep          # Fast grep (rg)
    fd               # Fast find
    curl             # HTTP client
    wget             # Download tool
    jq               # JSON processor
    yazi             # Terminal file manager
  ];

  shellHook = ''
    # shellHook runs before bwrap isolation - keep it minimal
    # Welcome message will be printed by the shell's init
  '';
}
