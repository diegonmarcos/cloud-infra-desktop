# Custom packages overlay
{ pkgs }:

{
  claude-code = pkgs.callPackage ./claude-code.nix { };
  gemini-cli = pkgs.callPackage ./gemini-cli.nix { };
  cloud-infra-mcp = pkgs.callPackage ./cloud-infra-mcp.nix { };
}
