# Home-manager user-level packages (Termux / nix-on-droid, aarch64)
# System-level packages live in flake.nix → environment.packages
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    busybox          # httpd — lightweight static file server
    mdbook
    iotop            # per-process disk I/O monitoring
    sysstat          # iostat, mpstat, pidstat, sar
    multitail        # multi-file tail with split view
    tree
    (callPackage ../pkgs/octocode.nix {})
    (callPackage ../pkgs/goose.nix {})
    dnsutils         # dig, nslookup — DNS health checks in MCP tools
    netcat-openbsd  # nc — WireGuard peer probing
    mtr              # TCP/UDP/ICMP traceroute — used by ~/triage.sh
    nmap             # TCP-connect port scanner (1-20005) — used by ~/triage.sh
    tcpdump          # packet capture — operator network debugging
    whois            # ASN / org lookups — used by ~/triage.sh WHOIS section
    ncurses          # clear, tput
    util-linux       # column, colrm, colcrt — table/column formatting
    git-filter-repo  # git history rewriting (purge secrets from commits)
    rsync            # build.sh deploy — sync dist/ to VMs
    cliphist         # clipboard history (wl-paste --watch cliphist store)
    # wrangler: installed from pkgsNew (24.11) in flake.nix environment.packages
    #           nixpkgs 24.05 has 3.34 which lacks [observability] support (needs 3.60+)
  ];
}
