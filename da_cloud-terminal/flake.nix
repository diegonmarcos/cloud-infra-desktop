{
  description = "cloud-terminal — Tauri (Rust) multi-profile terminal + tray";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Tauri v2 on Linux: WebKitGTK 4.1 + libsoup3 provide the system
        # webview; the rest is the Rust toolchain + build tooling. All of it
        # comes from here — build.sh never assumes the host has cargo/webkit.
        buildInputs = with pkgs; [
          webkitgtk_4_1
          gtk3
          libsoup_3
          glib
          openssl
          librsvg
          libayatana-appindicator # native system-tray (SNI) backend
        ];

        nativeBuildInputs = with pkgs; [
          rustc
          cargo
          cargo-tauri
          pkg-config
          wrapGAppsHook3
          nodejs_22 # only to `npm install` the xterm vendor assets
          imagemagick
          jq
        ];
      in {
        devShells.default = pkgs.mkShell {
          inherit buildInputs nativeBuildInputs;
          # WebKitGTK / libsoup pkg-config + runtime lib path so `cargo tauri
          # build` (and the resulting binary, when run from this shell) resolve
          # the webview.
          shellHook = ''
            export PKG_CONFIG_PATH="${pkgs.webkitgtk_4_1.dev}/lib/pkgconfig:${pkgs.libsoup_3.dev}/lib/pkgconfig:${pkgs.gtk3.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH"
            export WEBKIT_DISABLE_COMPOSITING_MODE=1
          '';
        };
      });
}
