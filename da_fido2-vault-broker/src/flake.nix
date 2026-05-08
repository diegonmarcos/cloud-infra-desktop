{
  description = "FIDO2 vault broker — virtual authenticator backed by Bitwarden/Vaultwarden";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            rustc
            cargo
            rust-analyzer
            clippy
            rustfmt
            pkg-config
            openssl
            tpm2-tss
            libudev-zero
            nodejs # for build.sh JSON parsing
          ];
        };

        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "fido2-vault-broker";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = with pkgs; [ openssl tpm2-tss ];
          doCheck = true;
        };
      });
}
