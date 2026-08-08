{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "mesh" (builtins.readFile ./scripts/mesh.sh))
  ];

  xdg.desktopEntries.mesh = {
    name = "Mesh Dashboard";
    comment = "Mesh network dashboard & status";
    exec = "mesh";
    icon = "network-wired";
    terminal = false;
    categories = [ "Network" "System" "Monitor" ];
  };
}
