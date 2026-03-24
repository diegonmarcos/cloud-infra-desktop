{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "connect" ''
      exec "$HOME/git/tools/a-cloud-connect/connect.sh" "$@"
    '')
  ];
}
