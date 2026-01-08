# Helper functions for Home Manager configuration
{ inputs, ... }:

{
  # Enable profiles by name - maps profile names to their module paths
  enableProfiles = profiles:
    builtins.map (p: ../modules/profiles/${p}.nix) profiles;

  # Merge multiple package lists
  mkProfilePackages = pkgs: profilePkgs:
    builtins.concatLists (builtins.attrValues profilePkgs);

  # Check if a profile is enabled
  hasProfile = profiles: name:
    builtins.elem name profiles;
}
