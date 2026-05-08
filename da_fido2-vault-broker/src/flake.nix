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
            # Needed when building with `--features fido2` — uhid-virt
            # transitively pulls bindgen → clang-sys → libclang and includes
            # <linux/uhid.h> from the kernel headers.
            llvmPackages.libclang
            linuxHeaders
            libnotify # `notify-send` for DesktopUpProvider (Phase B.6)
          ];
          # bindgen finds libclang via this env var.
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          # bindgen needs <linux/uhid.h> AND <sys/time.h> (transitively via
          # <linux/input.h>). On NixOS, libclang doesn't auto-pick the host
          # libc headers — feed them explicitly via -isystem so any -sys crate
          # using bindgen resolves the full chain without patching build.rs.
          BINDGEN_EXTRA_CLANG_ARGS = pkgs.lib.concatStringsSep " " [
            "-I${pkgs.linuxHeaders}/include"
            "-isystem ${pkgs.glibc.dev}/include"
            "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.versions.major (pkgs.lib.getVersion pkgs.llvmPackages.libclang)}/include"
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
