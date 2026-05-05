# security-net/secrets.nix — encryption + passwords + GPG/SSH audit
# Owns the programs.gpg + services.gpg-agent options. age + sops are also
# declared in containers-cloud/secrets.nix (parallel copy by design — see
# PLAN-module-split.md §2). Nix dedupes when both leaves are imported.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    # Encryption & Crypto
    gnupg
    age
    sops
    openssl

    # Password management (CLI)
    pass
    gopass

    # SSH audit (openssh client itself lives in core/network-basics.nix)
    ssh-audit
  ];

  # GPG configuration
  programs.gpg = {
    enable = true;
  };

  services.gpg-agent = {
    enable = true;
    enableSshSupport = false;  # Disable to stop SSH key passphrase prompts
    pinentryPackage = pkgs.pinentry-curses;
  };
}
