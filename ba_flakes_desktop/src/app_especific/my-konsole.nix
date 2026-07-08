{ config, pkgs, ... }:

# my-konsole: Alacritty as the KDE default terminal (Rust/GPU replacement for Konsole)

{
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        dimensions = { columns = 120; lines = 60; };
        opacity = 1.0;
      };
      scrolling.history = 5000;
      font = {
        normal.family = "JetBrainsMono Nerd Font";
        size = 11;
      };
      shell.program = "${pkgs.fish}/bin/fish";
      colors = {
        primary = {
          background = "#232629";
          foreground = "#fcfcfc";
        };
        normal = {
          black = "#232629";
          red = "#ed1515";
          green = "#11d116";
          yellow = "#f67400";
          blue = "#1d99f3";
          magenta = "#9b59b6";
          cyan = "#1abc9c";
          white = "#fcfcfc";
        };
        bright = {
          black = "#7f8c8d";
          red = "#c0392b";
          green = "#1cdc9a";
          yellow = "#fdbc4b";
          blue = "#3daee9";
          magenta = "#8e44ad";
          cyan = "#16a085";
          white = "#ffffff";
        };
      };
    };
  };

  xdg.desktopEntries."Alacritty" = {
    name = "Alacritty";
    comment = "A fast, cross-platform, OpenGL terminal emulator";
    exec = "${pkgs.alacritty}/bin/alacritty";
    icon = "Alacritty";
    terminal = false;
    categories = [ "System" "TerminalEmulator" ];
  };
}
