{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "connect" ''
      exec "$HOME/Mounts/Git/tools/a-cloud-connect/connect.sh" "$@"
    '')
  ];
}
