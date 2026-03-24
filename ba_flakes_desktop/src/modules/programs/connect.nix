{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "connect" ''
      exec "$HOME/git/tools/a-connect/connect.sh" "$@"
    '')
    (pkgs.writeShellScriptBin "sync" ''
      exec "$HOME/git/tools/a-sync/sync.sh" "$@"
    '')
  ];
}
