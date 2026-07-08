# antigravity — Google Antigravity Desktop (Agentic IDE), Electron app.
#
# No public stable download URL: the electron-updater endpoint
# (antigravity-hub-auto-updater-*.run.app) serves authenticated manifests only.
# Source is therefore the official tarball pinned by hash via requireFile —
# add it to the store once with:
#   nix-store --add-fixed sha256 ~/Downloads/Antigravity.tar.gz
#
# Runs inside buildFHSEnv: the binary expects an FHS layout
# (/lib64/ld-linux-x86-64.so.2 + system GTK/NSS/X11 stack).
{ lib, stdenv, requireFile, buildFHSEnv, makeDesktopItem, copyDesktopItems }:

let
  version = "2.2.1";

  src = requireFile {
    name = "Antigravity.tar.gz";
    sha256 = "sha256-prp3BG+SqhziHYoMZ0lUca9MK+EbpiTl2TWCGWmyCYk=";
    message = ''
      Antigravity ${version} has no public download URL.
      Fetch the Linux x64 tarball from https://antigravity.google and run:
        nix-store --add-fixed sha256 /path/to/Antigravity.tar.gz
    '';
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
    runScript = "${unpacked}/opt/antigravity/antigravity";
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
