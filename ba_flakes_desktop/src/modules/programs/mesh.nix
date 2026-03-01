{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "mesh" ''
      exec "$HOME/Mounts/Git/tools/a-Mesh/mesh.sh" "$@"
    '')
  ];
}
