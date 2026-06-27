{ pkgs }:
let
  electron  = pkgs.electron_34;
  pname     = "electron-terminal";
  version   = "1.0.0";

  # Wrapper args shared across all profiles
  commonWrapArgs = profile: [
    "--add-flags \"$out/lib/${pname}/main.js\""
    "--set ET_PROFILE         \"${profile}\""
    "--set ET_PROFILES_DIR    \"$out/lib/${pname}/data\""
    "--set ET_PANEL           \"$out/lib/${pname}/panel.html\""
    "--set ET_KONSOLE         \"${pkgs.kdePackages.konsole}/bin/konsole\""
    "--set ET_BASH            \"${pkgs.bash}/bin/bash\""
    "--set ET_XDG             \"${pkgs.xdg-utils}/bin/xdg-open\""
  ];
in
pkgs.stdenv.mkDerivation {
  inherit pname version;
  src = ../..;  # da_electron-terminal/ project root

  nativeBuildInputs = with pkgs; [
    typescript
    makeWrapper
    imagemagick
    jq
  ];

  buildPhase = ''
    # Compile TypeScript
    cd src/scripts
    tsc --project tsconfig.json
    cd ../..

    # Convert SVG icons to 128×128 PNGs
    for svg in src/assets/*.svg; do
      name=$(basename "$svg" .svg)
      convert -background none -resize 128x128 "$svg" "src/assets/$name.png"
    done
  '';

  installPhase = ''
    # Core runtime files
    install -Dm644 src/scripts/dist/main.js    $out/lib/${pname}/main.js
    install -Dm644 lib/panel.html              $out/lib/${pname}/panel.html

    # Profile data
    for f in src/data/profile-*.json; do
      install -Dm644 "$f" $out/lib/${pname}/data/$(basename "$f")
    done

    # Icons
    for f in src/assets/*.png; do
      install -Dm644 "$f" $out/share/icons/${pname}/$(basename "$f")
    done

    # switch-gui.sh (nix-flakes only)
    install -Dm755 src/scripts/switch-gui.sh   $out/lib/${pname}/switch-gui.sh
    substituteInPlace $out/lib/${pname}/switch-gui.sh \
      --replace '@BASH@'    '${pkgs.bash}/bin/bash' \
      --replace '@KDIALOG@' '${pkgs.kdePackages.kdialog}/bin/kdialog' \
      --replace '@QDBUS@'   '${pkgs.kdePackages.qdbus}/bin/qdbus' \
      --replace '@JQ@'      '${pkgs.jq}/bin/jq'

    # Per-profile binaries
    makeWrapper ${electron}/bin/electron $out/bin/electron-terminal-cloud \
      --add-flags "$out/lib/${pname}/main.js" \
      --set ET_PROFILE      "cloud" \
      --set ET_PROFILES_DIR "$out/lib/${pname}/data" \
      --set ET_PANEL        "$out/lib/${pname}/panel.html" \
      --set ET_ICON         "$out/share/icons/${pname}/cloud.png" \
      --set ET_KONSOLE      "${pkgs.kdePackages.konsole}/bin/konsole" \
      --set ET_BASH         "${pkgs.bash}/bin/bash" \
      --set ET_XDG          "${pkgs.xdg-utils}/bin/xdg-open"

    makeWrapper ${electron}/bin/electron $out/bin/electron-terminal-nix-flakes \
      --add-flags "$out/lib/${pname}/main.js" \
      --set ET_PROFILE      "nix-flakes" \
      --set ET_PROFILES_DIR "$out/lib/${pname}/data" \
      --set ET_PANEL        "$out/lib/${pname}/panel.html" \
      --set ET_ICON         "$out/share/icons/${pname}/nix-flakes.png" \
      --set ET_SWITCH_GUI   "$out/lib/${pname}/switch-gui.sh" \
      --set ET_KONSOLE      "${pkgs.kdePackages.konsole}/bin/konsole" \
      --set ET_BASH         "${pkgs.bash}/bin/bash" \
      --set ET_XDG          "${pkgs.xdg-utils}/bin/xdg-open"
  '';

  meta.description = "Electron terminal with profile-based systray (Cloud + Nix-Flakes)";
}
