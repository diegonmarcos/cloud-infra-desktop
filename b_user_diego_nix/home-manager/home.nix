{ config, pkgs, ... }:

{
  home.username = "diego";
  home.homeDirectory = "/home/diego";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # KDE PLASMA CONFIGURATION FILES
  # ═══════════════════════════════════════════════════════════════════════════

  home.file = {
    # Theme & Colors (Breeze Dark)
    ".config/kdeglobals".text = ''
      [ColorEffects:Disabled]
      ChangeSelectionColor=
      Color=56,56,56
      ColorAmount=0
      ColorEffect=0
      ContrastAmount=0.65
      ContrastEffect=1
      Enable=
      IntensityAmount=0.1
      IntensityEffect=2

      [ColorEffects:Inactive]
      ChangeSelectionColor=true
      Color=112,111,110
      ColorAmount=0.025
      ColorEffect=2
      ContrastAmount=0.1
      ContrastEffect=2
      Enable=false
      IntensityAmount=0
      IntensityEffect=0

      [Colors:Button]
      BackgroundAlternate=30,87,116
      BackgroundNormal=49,54,59
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Complementary]
      BackgroundAlternate=30,87,116
      BackgroundNormal=42,46,50
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Header]
      BackgroundAlternate=42,46,50
      BackgroundNormal=49,54,59
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Header][Inactive]
      BackgroundAlternate=49,54,59
      BackgroundNormal=42,46,50
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Selection]
      BackgroundAlternate=30,87,116
      BackgroundNormal=61,174,233
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=252,252,252
      ForegroundInactive=161,169,177
      ForegroundLink=253,188,75
      ForegroundNegative=176,55,69
      ForegroundNeutral=198,92,0
      ForegroundNormal=252,252,252
      ForegroundPositive=23,104,57
      ForegroundVisited=155,89,182

      [Colors:Tooltip]
      BackgroundAlternate=42,46,50
      BackgroundNormal=49,54,59
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:View]
      BackgroundAlternate=35,38,41
      BackgroundNormal=27,30,32
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Window]
      BackgroundAlternate=49,54,59
      BackgroundNormal=42,46,50
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [General]
      ColorSchemeHash=babca25f3a5cf7ece26a85de212ab43d0a141257

      [KDE]
      LookAndFeelPackage=org.kde.breezedark.desktop

      [WM]
      activeBackground=49,54,59
      activeBlend=252,252,252
      activeForeground=252,252,252
      inactiveBackground=42,46,50
      inactiveBlend=161,169,177
      inactiveForeground=161,169,177
    '';

    # KWin - Display Scale 1.5x, Night Color, Tiling
    ".config/kwinrc".text = ''
      [Desktops]
      Id_1=63e7e852-00b9-4768-b3f8-11f2cdc5d193
      Number=1
      Rows=1

      [NightColor]
      Active=true
      Mode=Constant
      NightTemperature=2200

      [Tiling]
      padding=4

      [Xwayland]
      Scale=1.5
    '';

    # Keyboard Layout - Spanish
    ".config/kxkbrc".text = ''
      [Layout]
      DisplayNames=
      LayoutList=es
      LayoutLoopCount=-1
      Model=pc105
      Options=
      ResetOldOptions=false
      ShowFlag=false
      ShowLabel=true
      ShowLayoutIndicator=true
      ShowSingle=false
      SwitchMode=Global
      Use=true
    '';

    # Locale - Spanish date format (dd/mm/yyyy), 24h time
    ".config/plasma-localerc".text = ''
      [Formats]
      LC_TIME=es_ES.UTF-8
      LC_MEASUREMENT=es_ES.UTF-8
      LC_MONETARY=es_ES.UTF-8
      LC_NUMERIC=es_ES.UTF-8
    '';

    # Touchpad - Tap drag lock enabled
    ".config/kcminputrc".text = ''
      [Libinput][1118][2479][Microsoft Surface 045E:09AF Touchpad]
      TapDragLock=true

      [Mouse]
      X11LibInputXAccelProfileFlat=true
    '';
  };
}
