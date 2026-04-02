{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "mesh" ''
      exec "$HOME/git/tools/3-dashboards/mesh/mesh.sh" "$@"
    '')
  ];
}
