{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "connect" ''
      exec "$HOME/git/tools/3-dashboards/connect.sh" "$@"
    '')
    (pkgs.writeShellScriptBin "sync" ''
      exec "$HOME/git/tools/5-infos/z-others/a-sync/sync.sh" "$@"
    '')
  ];

  xdg.desktopEntries = {
    connect = {
      name = "Connect Dashboard";
      comment = "Network connectivity dashboard";
      exec = "connect";
      icon = "network-wired";
      terminal = false;
      categories = [ "Network" "System" ];
    };
    sync = {
      name = "Sync";
      comment = "File & data synchronization";
      exec = "sync";
      icon = "folder-sync";
      terminal = true;
      categories = [ "System" "Utility" ];
    };
  };
}
