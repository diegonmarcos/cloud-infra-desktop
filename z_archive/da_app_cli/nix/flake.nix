{
  description = "Diego's CLI Development Container";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";  # Stable, pinned
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        # Build container: nix build .#container
        packages.container = import ./container.nix { inherit pkgs; };
        packages.default = self.packages.${system}.container;

        # Dev shell: nix develop (for testing without container)
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Same tools as container for local testing
            gcc clang gnumake cmake
            python311 poetry
            nodejs_20
            rustup go
            git gh
            ripgrep fd bat fzf jq
          ];
        };
      }
    );
}
