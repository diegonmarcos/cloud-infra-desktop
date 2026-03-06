{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "cloud-connect" ''
      exec "$HOME/Mounts/Git/tools/a-cloud-connect/cloud-connect.sh" "$@"
    '')
  ];
}
