# antigravity — Google Antigravity Desktop (Agentic IDE), Electron app.
#
# Official tarball from Google's public GCS bucket. Per-version build id in
# the path (discoverable via the AUR `antigravity` PKGBUILD `_build` on
# version bumps — the updater endpoint serves authenticated manifests only).
#
# Runs inside buildFHSEnv: the binary expects an FHS layout
# (/lib64/ld-linux-x86-64.so.2 + system GTK/NSS/X11 stack).
{ lib, stdenv, fetchurl, buildFHSEnv, makeDesktopItem, copyDesktopItems, writeShellScript, asar }:

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
    # Known upstream bug (all Linux distros): Antigravity can leave orphaned
    # helpers on close that wedge the session (freeze-on-close, see
    # jacopone/antigravity-nix README). Reap this install's processes on exit.
    # (The "Invalid environment block" crash was a vault-keys bug — multi-line
    # private keys exported into the login env; fixed at the source in
    # vault/build.sh, which now exports <NAME>_FILE paths, not the material.)
    runScript = writeShellScript "antigravity-run"
      (builtins.replaceStrings [ "@unpacked@" ] [ "${unpacked}" ]
        (builtins.readFile ./scripts/antigravity-run.sh));
  };
in
stdenv.mkDerivation {
  pname = "antigravity";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ copyDesktopItems asar ];

  desktopItems = [
    (makeDesktopItem {
      name = "antigravity";
      exec = "antigravity %U";
      icon = "antigravity";
      desktopName = "Antigravity";
      genericName = "Agentic IDE";
      comment = "Google Antigravity — Agentic Desktop Application";
      categories = [ "Development" "IDE" ];
      # Electron sets the Wayland app_id / X11 WM class to the app name
      # ("antigravity"); KDE task manager matches the window to this entry via
      # StartupWMClass, so the taskbar shows the Antigravity icon (not generic).
      startupWMClass = "antigravity";
    })
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    ln -s ${fhs}/bin/antigravity $out/bin/antigravity

    # Icon lives inside the Electron asar (/icon.png, 512x512) — extract it into
    # the hicolor theme so the desktop entry's Icon=antigravity resolves.
    mkdir -p $out/share/icons/hicolor/512x512/apps
    asar extract-file ${unpacked}/opt/antigravity/resources/app.asar icon.png
    cp icon.png $out/share/icons/hicolor/512x512/apps/antigravity.png

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
