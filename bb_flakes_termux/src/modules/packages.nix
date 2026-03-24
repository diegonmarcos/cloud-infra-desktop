# Home-manager user-level packages (Termux / nix-on-droid, aarch64)
# System-level packages live in flake.nix → environment.packages
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    busybox          # httpd — lightweight static file server
    mdbook
    tree
    (callPackage ../pkgs/octocode.nix {})
    dnsutils         # dig, nslookup — DNS health checks in MCP tools
    netcat-openbsd  # nc — WireGuard peer probing
    ncurses          # clear, tput
    rsync            # build.sh deploy — sync dist/ to VMs
    # wrangler: installed from pkgsNew (24.11) in flake.nix environment.packages
    #           nixpkgs 24.05 has 3.34 which lacks [observability] support (needs 3.60+)
  ];
}
