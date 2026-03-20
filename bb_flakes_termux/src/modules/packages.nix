# Home-manager user-level packages (Termux / nix-on-droid, aarch64)
# System-level packages live in flake.nix → environment.packages
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    busybox          # httpd — lightweight static file server
    mdbook
    tree
    dnsutils         # dig, nslookup — DNS health checks in MCP tools
    netcat-openbsd  # nc — WireGuard peer probing
    ncurses          # clear, tput
    rsync            # build.sh deploy — sync dist/ to VMs
    wrangler         # Cloudflare Worker CLI — build.sh ship for CF workers
  ];
}
