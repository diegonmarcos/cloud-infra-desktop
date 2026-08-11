{ config, lib, pkgs, ... }:

# Konsole terminal emulator configuration

let
  # konsolerc CANNOT be a store symlink: KConfig rewrites it on every settings
  # change (and on some window events), so a read-only /nix/store target makes
  # Konsole print `Configuration file "/nix/store/…-hm_.configkonsolerc" not
  # writable.` and drop the change. Declare the defaults here, seed a real
  # mutable copy on activation.
  konsolercDefaults = pkgs.writeText "konsolerc" ''
    [Desktop Entry]
    DefaultProfile=Profile 1.profile

    [General]
    ConfigVersion=1

    [KonsoleWindow]
    RememberWindowSize=false

    [MainWindow]
    MenuBar=Disabled
    ToolBarsMovable=Disabled

    [Notification Messages]
    quick-commands-question=false

    [UiSettings]
    ColorScheme=
  '';
in
{
  # Konsole profile
  home.file.".local/share/konsole/Profile 1.profile".text = ''
    [Appearance]
    ColorScheme=Breeze
    Font=JetBrainsMono NF,11,-1,5,50,0,0,0,0,0

    [General]
    Command=/usr/bin/fish
    Name=Profile 1
    Parent=FALLBACK/
    TerminalColumns=120
    TerminalRows=60

    [Scrolling]
    HistorySize=5000
  '';

  # Konsole main config — seeded, not symlinked (see konsolercDefaults above).
  # Replaces a store symlink left by an earlier generation; never overwrites a
  # real file, so settings the user changes in the GUI survive rebuilds.
  # ponytail: same shape applies to "Profile 1.profile" if GUI profile edits
  # ever start failing the same way — seed it the same way then.
  home.activation.seedKonsolerc = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    DST="$HOME/.config/konsolerc"
    if [ -L "$DST" ] || [ ! -e "$DST" ]; then
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config"
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$DST"
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0644 ${konsolercDefaults} "$DST"
      echo "[konsole] seeded writable konsolerc"
    fi
    )
  '';

  # Breeze color scheme
  home.file.".local/share/konsole/Breeze.colorscheme".text = ''
    [Background]
    Color=35,38,41

    [BackgroundFaint]
    Color=35,38,41

    [BackgroundIntense]
    Color=35,38,41

    [Color0]
    Color=35,38,41

    [Color0Faint]
    Color=49,54,59

    [Color0Intense]
    Color=127,140,141

    [Color1]
    Color=237,21,21

    [Color1Faint]
    Color=120,50,40

    [Color1Intense]
    Color=192,57,43

    [Color2]
    Color=17,209,22

    [Color2Faint]
    Color=23,162,98

    [Color2Intense]
    Color=28,220,154

    [Color3]
    Color=246,116,0

    [Color3Faint]
    Color=182,86,25

    [Color3Intense]
    Color=253,188,75

    [Color4]
    Color=29,153,243

    [Color4Faint]
    Color=27,102,143

    [Color4Intense]
    Color=61,174,233

    [Color5]
    Color=155,89,182

    [Color5Faint]
    Color=97,74,115

    [Color5Intense]
    Color=142,68,173

    [Color6]
    Color=26,188,156

    [Color6Faint]
    Color=24,108,96

    [Color6Intense]
    Color=22,160,133

    [Color7]
    Color=252,252,252

    [Color7Faint]
    Color=99,104,109

    [Color7Intense]
    Color=255,255,255

    [Foreground]
    Color=252,252,252

    [ForegroundFaint]
    Color=239,240,241

    [ForegroundIntense]
    Color=255,255,255

    [General]
    Anchor=0.5,0.5
    Blur=false
    ColorRandomization=false
    Description=Breeze
    FillStyle=Tile
    Opacity=1
    Wallpaper=
    WallpaperFlipType=NoFlip
    WallpaperOpacity=1
  '';
}
