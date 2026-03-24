{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "mesh" ''
      exec "$HOME/git/tools/a-Mesh/mesh.sh" "$@"
    '')
  ];
}
