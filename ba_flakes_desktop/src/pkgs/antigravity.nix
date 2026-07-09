# antigravity — Google Antigravity Desktop (Agentic IDE), Electron app.
#
# Official tarball from Google's public GCS bucket. Per-version build id in
# the path (discoverable via the AUR `antigravity` PKGBUILD `_build` on
# version bumps — the updater endpoint serves authenticated manifests only).
#
# Runs inside buildFHSEnv: the binary expects an FHS layout
# (/lib64/ld-linux-x86-64.so.2 + system GTK/NSS/X11 stack).
{ lib, stdenv, fetchurl, buildFHSEnv, makeDesktopItem, copyDesktopItems, writeShellScript }:

let
  version = "2.2.1";
  build = "5287492581195776";

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-hub/${version}-${build}/linux-x64/Antigravity.tar.gz";
    hash = "sha256-prp3BG+SqhziHYoMZ0lUca9MK+EbpiTl2TWCGWmyCYk=";
  };

  unpacked = stdenv.mkDerivation {
    pname = "antigravity-unpacked";
    inherit version src;
    sourceRoot = "Antigravity-x64";
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/opt/antigravity
      cp -r . $out/opt/antigravity/
      runHook postInstall
    '';
  };

  fhs = buildFHSEnv {
    name = "antigravity";
    targetPkgs = pkgs: with pkgs; [
      glib
      glibc
      libglvnd
      mesa
      libdrm
      xdg-utils
      glib-networking
      gsettings-desktop-schemas
      udev
      libsecret
      libnotify
      expat
      fontconfig
      freetype
      cairo
      pango
      gdk-pixbuf
      nss
      nspr
      atk
      at-spi2-atk
      cups
      dbus
      gtk3
      alsa-lib
      libxkbcommon
      xorg.libX11
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXrandr
      xorg.libxcb
      icu
      zlib
    ];
    profile = ''
      export XDG_DATA_DIRS=/usr/share:$XDG_DATA_DIRS
    '';
    # Two hardening steps wrap the real binary:
    #
    # 1. Drop every env var whose value contains a newline before launch.
    #    NixOS vault-keys (~/git/vault/vault-keys-fish.fish, sourced by
    #    config.fish) export multi-line SSH/GPG/JWKS private keys into the
    #    login env. Antigravity snapshots the shell env (shell-env) and passes
    #    it to child_process.spawn, which rejects a multi-line environment
    #    block -> "Invalid environment block." Stripping them also stops the
    #    app + its bundled git/telemetry from ever seeing your private keys.
    #    Computed at runtime (env -0), never a hardcoded list.
    #
    # 2. Known upstream bug (all Linux distros): Antigravity can leave orphaned
    #    helpers on close that wedge the session (freeze-on-close, see
    #    jacopone/antigravity-nix README). Reap this install's processes on exit.
    runScript = writeShellScript "antigravity-run" ''
      while IFS= read -r -d "" kv; do
        name=''${kv%%=*}
        case "''${kv#*=}" in
          *$'\n'*) unset "$name" 2>/dev/null || true ;;
        esac
      done < <(env -0)

      "${unpacked}/opt/antigravity/antigravity" "$@"
      rc=$?
      pkill -9 -f "${unpacked}/opt/antigravity" 2>/dev/null || true
      exit $rc
    '';
  };
in
stdenv.mkDerivation {
  pname = "antigravity";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ copyDesktopItems ];

  desktopItems = [
    (makeDesktopItem {
      name = "antigravity";
      exec = "antigravity %U";
      desktopName = "Antigravity";
      genericName = "Agentic IDE";
      comment = "Google Antigravity — Agentic Desktop Application";
      categories = [ "Development" "IDE" ];
    })
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    ln -s ${fhs}/bin/antigravity $out/bin/antigravity
    runHook postInstall
  '';

  meta = with lib; {
    description = "Google Antigravity Desktop — agentic IDE (Electron)";
    homepage = "https://antigravity.google";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "antigravity";
  };
}
