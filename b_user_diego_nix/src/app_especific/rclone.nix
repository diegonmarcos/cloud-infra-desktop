{ config, pkgs, lib, ... }:

# Rclone configuration
# NOTE: This file contains SENSITIVE tokens - use sops-nix or agenix for secrets!
# The actual rclone.conf should be managed separately or encrypted.

{
  home.packages = [ pkgs.rclone ];

  # Template for rclone remotes (tokens redacted)
  # Copy this to ~/.config/rclone/rclone.conf and fill in tokens
  home.file.".config/rclone/rclone.conf.template".text = ''
    # Google Drive - diegonmarcos1@gmail.com
    [Gdrive_dnm]
    type = drive
    scope = drive
    token = {"access_token":"REDACTED","token_type":"Bearer","refresh_token":"REDACTED","expiry":"REDACTED"}
    team_drive =

    # SFTP - GCP Arch 1 (Proxy/Auth server)
    [GCP_micro_1]
    type = sftp
    host = 35.226.147.64
    user = fuse
    key_file = ~/.ssh/google_compute_engine
    shell_type = unix
    md5sum_command = md5sum
    sha1sum_command = sha1sum

    # SFTP - OCI Micro 0 (web-server-1 / Mail)
    [OCI_micro_0]
    type = sftp
    host = 130.110.251.193
    user = diego
    key_file = ~/.ssh/id_rsa
    shell_type = unix
    md5sum_command = md5sum
    sha1sum_command = sha1sum

    # SFTP - OCI Micro 1 (services-server-1 / Analytics)
    [OCI_micro_1]
    type = sftp
    host = 129.151.228.66
    user = diego
    key_file = ~/.ssh/id_rsa
    shell_type = unix
    md5sum_command = md5sum
    sha1sum_command = sha1sum

    # SFTP - OCI Flex 1 (dev-server-1 / Photos/Sync)
    [OCI_flex_1]
    type = sftp
    host = 84.235.234.87
    user = diego
    key_file = ~/.ssh/id_rsa
    shell_type = unix
    md5sum_command = md5sum
    sha1sum_command = sha1sum
  '';

  # Rclone mount helper scripts
  home.file.".local/bin/gdrive-mount".text = ''
    #!/bin/bash
    # Mount Google Drive
    mkdir -p ~/Documents/Gdrive
    rclone mount Gdrive_dnm: ~/Documents/Gdrive \
      --vfs-cache-mode full \
      --vfs-cache-max-size 1G \
      --daemon
  '';
  home.file.".local/bin/gdrive-mount".executable = true;

  home.file.".local/bin/gdrive-umount".text = ''
    #!/bin/bash
    # Unmount Google Drive
    fusermount -u ~/Documents/Gdrive
  '';
  home.file.".local/bin/gdrive-umount".executable = true;
}
