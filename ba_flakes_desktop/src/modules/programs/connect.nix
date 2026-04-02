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
}
