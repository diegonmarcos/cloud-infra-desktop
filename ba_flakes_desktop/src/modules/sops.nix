{ config, pkgs, lib, ... }:

# sops-nix secrets configuration for home-manager
# Secrets are decrypted at runtime to /run/user/<uid>/secrets/

{
  # Install sops for editing secrets
  home.packages = [ pkgs.sops pkgs.age ];

  # Symlink age key from vault to expected location
  xdg.configFile."sops/age/keys.txt".source =
    config.lib.file.mkOutOfStoreSymlink "/home/diego/git/cloud-vault/A0_keys/providers/system/ssh_asymmetric/age_keys.txt";

  sops = {
    # Age key location (symlinked from vault)
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";

    # Default secrets file
    defaultSopsFile = ../secrets/secrets.yaml;

    # Secrets definitions
    # Each secret will be available at: config.sops.secrets.<name>.path
    # Runtime location: /run/user/<uid>/secrets/<name>

    secrets = {
      # WakaTime API key for VSCode/editors
      wakatime_api_key = {
        # path = "/run/user/1000/secrets/wakatime_api_key";  # auto-generated
      };

      # Rclone Google Drive token
      rclone_gdrive_token = {};

      # SSH key paths (references, not actual keys)
      ssh_key_oci = {};
      ssh_key_gcp = {};
    };
  };

  # Helper script to show secret paths
  home.file.".local/bin/sops-paths".text = builtins.readFile ./scripts/sops-paths.sh;
  home.file.".local/bin/sops-paths".executable = true;
}
