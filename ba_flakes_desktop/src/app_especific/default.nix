{ config, pkgs, lib, ... }:

# App-specific configurations
# Import individual app configs as needed

{
  imports = [
    ./vscode.nix
    ./btop.nix
    ./konsole.nix
    ./rclone.nix
  ];
}
