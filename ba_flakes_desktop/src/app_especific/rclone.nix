{ config, pkgs, lib, ... }:

# Rclone configuration
# Google Drive token is managed by sops-nix at:
#   /run/user/<uid>/secrets/rclone_gdrive_token
#
# To configure rclone with the secret token:
#   rclone config set Gdrive_dnm token "$(cat /run/user/$(id -u)/secrets/rclone_gdrive_token)"

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

    # The two drives named by account rather than by whose they are. Gdrive_dnm
    # above predates them and does not say which account it holds, which is the
    # whole problem with a name like "me": the panel lists remotes, and a list
    # of remotes has to say what each one IS.
    #
    # Tokens are REDACTED here, as everywhere in this template. Authorise each
    # one once, on the machine, with:
    #     rclone config reconnect g-workspace-drive:
    #     rclone config reconnect g-personal-drive:
    # which opens the browser for that account and writes the token into the
    # real ~/.config/rclone/rclone.conf. Nothing secret is ever committed.

    # Google Drive - me@diegonmarcos.com (workspace)
    [g-workspace-drive]
    type = drive
    scope = drive
    token = {"access_token":"REDACTED","token_type":"Bearer","refresh_token":"REDACTED","expiry":"REDACTED"}
    team_drive =

    # Google Drive - diegonmarcos1@gmail.com (personal)
    [g-personal-drive]
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
