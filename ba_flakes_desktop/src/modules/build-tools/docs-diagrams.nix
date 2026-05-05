# build-tools/docs-diagrams.nix — documentation generators + diagram tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    pandoc
    doxygen
    graphviz         # dot — network graphs, auto-layout
    d2               # architecture diagrams, clean modern style
    plantuml         # UML, sequence diagrams, enterprise
    pikchr           # inline SVG, precise positioning
  ];
}
