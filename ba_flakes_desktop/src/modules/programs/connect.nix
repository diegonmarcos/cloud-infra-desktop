{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "connect" (builtins.readFile ./scripts/connect.sh))
    (pkgs.writeShellScriptBin "sync" (builtins.readFile ./scripts/sync.sh))
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
