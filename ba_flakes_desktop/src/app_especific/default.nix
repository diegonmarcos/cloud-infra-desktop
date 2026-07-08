{ config, pkgs, lib, ... }:

# App-specific configurations
# Import individual app configs as needed

{
  imports = [
    ./vscode.nix
    ./btop.nix
    ./konsole.nix
    ./konsole-ssh-manager-quick-commands.nix
    ./my-konsole.nix
    ./rclone.nix
  ];
}
