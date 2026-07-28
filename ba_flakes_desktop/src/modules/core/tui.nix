# core/tui.nix — terminal UIs and viewers
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    yazi             # TUI file manager
    browsh           # terminal web browser (headless Firefox rendering)
    ncdu             # disk usage analyzer
    duf              # df replacement
    tree             # directory tree view
  ];

  xdg.desktopEntries = {
    browsh = {
      name = "Browsh";
      comment = "Terminal web browser (headless Firefox)";
      exec = "browsh";
      icon = "web-browser";
      terminal = true;
      categories = [ "Network" "WebBrowser" ];
    };
  };
}
