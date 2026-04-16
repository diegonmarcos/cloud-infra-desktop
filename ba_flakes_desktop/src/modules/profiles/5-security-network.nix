# Profile 5: Security & Networking
# Privacy, analysis, encryption
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Privacy & Anonymity
    tor
    torsocks
    dnscrypt-proxy2

    # VPN
    wireguard-tools
    openvpn

    # Network analysis
    nmap
    netcat-openbsd
    mtr
    tcpdump
    wireshark-cli
    tshark
    iftop
    nethogs

    # Security scanning
    lynis

    # Encryption & Crypto
    gnupg
    age
    sops
    openssl

    # Password management
    pass
    gopass
    bitwarden-desktop  # Vaultwarden/Bitwarden GUI client

    # SSH tools
    openssh
    ssh-audit

    # Forensics & Analysis
    yara             # malware pattern matching (used by cloud-data-reports)
    binwalk
    hexyl
    xxd
    binutils         # includes strings, objdump, etc.

    # Web security
    httpie

    # SSL/TLS
    certbot

    # Firewall
    iptables
    nftables
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
