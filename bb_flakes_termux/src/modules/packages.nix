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
    # Termux:API CLI helpers (termux-vibrate, termux-toast, …) are NOT
    # wired here — the upstream C bridge (termux-api.c) includes
    # <sys/endian.h>, a bionic-only header that the nix-on-droid build
    # env doesn't expose, so the derivation fails compile. The Termux:API
    # APK alone is useless without this CLI half. Fix path: patch the
    # derivation to substitute <endian.h> + remap htobe→hton names, OR
    # build with a bionic sysroot. Pending — for now haptics work
    # happens through Cloud SuperApp's in-process VibrationEffect API.
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
    rbw              # Rust Bitwarden CLI — `rbw get <name>` to pipe secrets (e.g. into `gh secret set`)
    pinentry-curses  # TUI pinentry for rbw master-password unlock (no GUI/X on nix-on-droid)
    # android-tools  # adb/fastboot — DISABLED. Only useful from PLAIN Termux
                     #   (com.termux), NOT this nix-on-droid proot: adb pairing
                     #   reaches the device but our charger/USB-PD debug path moved
                     #   into Cloud-SuperApp's own shell-domain server (libs:
                     #   shizuku-adb-debug-tools, /api/adb/*), so adb here is moot.
                     #   Re-enable (uncomment) only if you need adb from stock Termux.
    # wrangler: installed from pkgsNew (24.11) in flake.nix environment.packages
    #           nixpkgs 24.05 has 3.34 which lacks [observability] support (needs 3.60+)
  ];
}
