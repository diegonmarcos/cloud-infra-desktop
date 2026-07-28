{ lib, stdenv, fetchurl, autoPatchelfHook, dpkg, wrapGAppsHook3
, glib, gtk3, cairo, pango, gdk-pixbuf
, nss, nspr, cups, expat, dbus
, libX11, libXcomposite, libXdamage, libXext, libXfixes, libXrandr
, libxcb, libxkbcommon, libgbm
, alsa-lib, systemd, libdrm, atk, at-spi2-atk
, makeDesktopItem, copyDesktopItems
}:

let
  version = "1.44.0";
  assets = {
    x86_64-linux = {
      url = "https://github.com/aaif-goose/goose/releases/download/v${version}/goose_${version}_amd64.deb";
      hash = "sha256-uc9SPvARTIfvz0ozvd9Ssq23ZCak+6Ued70XVUXfghk=";
    };
    # No aarch64 .deb released — only x86_64 desktop for now
  };
  asset = assets.${stdenv.hostPlatform.system} or (throw "goose-desktop: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "goose-desktop";
  inherit version;

  src = fetchurl {
    inherit (asset) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    wrapGAppsHook3
    copyDesktopItems
  ];

  buildInputs = [
    glib gtk3 cairo pango gdk-pixbuf
    nss nspr cups expat dbus
    libX11 libXcomposite libXdamage libXext libXfixes libXrandr
    libxcb libxkbcommon libgbm
    alsa-lib systemd libdrm atk at-spi2-atk
    stdenv.cc.cc.lib
  ];

  desktopItems = [
    (makeDesktopItem {
      name = "goose";
      exec = "goose-desktop";
      icon = "goose";
      desktopName = "Goose";
      comment = "AI-powered developer agent (desktop)";
      categories = [ "Development" ];
      mimeTypes = [ "x-scheme-handler/goose" ];
    })
  ];

  # dpkg-deb -x fails on chrome-sandbox (SUID bit, mode 4755) in the sandbox.
  # Strip modes by extracting with --no-same-permissions, then fix the bits
  # we actually care about in installPhase. The Electron runtime doesn't use
  # the SUID sandbox under nix (it's sandboxed at the kernel level), so the
  # missing setuid bit is harmless here.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile $src | tar --no-same-permissions -xf -
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r usr/* $out/

    # Remove the deb's bin/goose symlink — it collides with the goose CLI
    # package. We expose the desktop binary as bin/goose-desktop instead.
    rm -f $out/bin/goose

    # Remove the deb's desktop entry — it hardcodes Exec=/usr/lib/goose/Goose
    # (wrong path in nix). copyDesktopItems installs our makeDesktopItem version
    # with Exec=goose-desktop instead.
    rm -f $out/share/applications/goose.desktop

    # Rename the binary to avoid clash with the CLI goose package
    mkdir -p $out/bin
    ln -sf $out/lib/goose/Goose $out/bin/goose-desktop

    # Install icon into hicolor theme
    mkdir -p $out/share/icons/hicolor/1024x1024/apps
    mv $out/share/pixmaps/goose.png $out/share/icons/hicolor/1024x1024/apps/
    rm -rf $out/share/pixmaps

    runHook postInstall
  '';

  meta = with lib; {
    description = "Goose Desktop — AI-powered developer agent by Block (MCP-native, Electron UI)";
    homepage = "https://github.com/block/goose";
    license = licenses.asl20;
    platforms = builtins.attrNames assets;
    mainProgram = "goose-desktop";
  };
}
