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

        # LEAN runtime shell for `build.sh run` — ONLY the runtime libs the
        # prebuilt binary links (webkit/gtk/soup/glib/appindicator), NO build
        # toolchain (rust, cargo-tauri, node, imagemagick). `run` uses this to
        # resolve LD_LIBRARY_PATH, so launching a fetched binary no longer
        # realizes the whole dev closure (the "thousands of compile steps").
        devShells.runtime = pkgs.mkShell {
          inherit buildInputs;
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH"
          '';
        };

        # Plain evaluated string (NOT a devShell/derivation) — `nix eval --raw`
        # returns it in milliseconds, no shellHook, no shell spawn, no build.
        # `build.sh run` reads this ONCE and caches it to disk; every launch
        # after that is a straight `exec`, like any other app — no more paying
        # a `nix develop` (flake realize + shell spawn) tax on every single
        # launch just to read one env var.
        runtimeLibPath = pkgs.lib.makeLibraryPath buildInputs;
      });
}
