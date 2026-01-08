{ config, pkgs, lib, ... }:

# sops-nix secrets configuration for home-manager
# Secrets are decrypted at runtime to /run/user/<uid>/secrets/

{
  # Install sops for editing secrets
  home.packages = [ pkgs.sops pkgs.age ];

  sops = {
    # Age key location (generated with: age-keygen -o ~/.config/sops/age/keys.txt)
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
  home.file.".local/bin/sops-paths".text = ''
    #!/bin/bash
    echo "=== SOPS Secret Paths ==="
    echo ""
    echo "WakaTime API Key:"
    echo "  Path: /run/user/$(id -u)/secrets/wakatime_api_key"
    echo "  Read: cat /run/user/$(id -u)/secrets/wakatime_api_key"
    echo ""
    echo "Rclone GDrive Token:"
    echo "  Path: /run/user/$(id -u)/secrets/rclone_gdrive_token"
    echo ""
    echo "SSH Keys:"
    echo "  OCI: cat /run/user/$(id -u)/secrets/ssh_key_oci"
    echo "  GCP: cat /run/user/$(id -u)/secrets/ssh_key_gcp"
    echo ""
    echo "To edit secrets:"
    echo "  cd ~/mnt_git/unix/b_user_diego_nix/src"
    echo "  sops secrets/secrets.yaml"
  '';
  home.file.".local/bin/sops-paths".executable = true;
}
