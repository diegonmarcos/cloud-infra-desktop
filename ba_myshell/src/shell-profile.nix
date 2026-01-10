{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Isolation
    bubblewrap       # Sandbox for real HOME isolation

    # Shell Profile - Essential shell experience (~200MB)
    fish             # Friendly Interactive Shell (default)
    zsh              # Z Shell with powerful features
    starship         # Cross-shell prompt
    eza              # Modern ls replacement
    bat              # Cat with syntax highlighting
    fzf              # Fuzzy finder
    zoxide           # Smart cd
  ];

  shellHook = ''
    # Welcome message is printed by launcher after isolation setup
  '';
}
