# environment.packages — the system package set. Kept apart from system.nix
# because it is a long, frequently-edited list and mixing it with the handful of
# system options above made both harder to read.
{ config, lib, pkgs, pkgsNew, pkgsUnstable, termux-am, jbMonoNerd, nix-on-droid, ... }:

{
  environment.packages = with pkgs; [
    # Nerd Fonts (for terminal icons)
    jbMonoNerd  # single nerdfonts derivation — a second override with a different font list built a SEPARATE multi-hundred-MB package (2026-08-08 audit)

    # Core Tools
    nano
    gnused
    gnugrep
    git
    curl
    wget
    # vim — provided by programs.vim in common.nix
    coreutils
    openssh
    strace
    unison
    rclone
    procps
    gawk
    findutils
    fzf
    atuin     # shell history search (arrow-up, Ctrl+R)
    tealdeer  # tldr — simplified man pages
    browsh    # terminal web browser (headless Firefox rendering)
    iproute2  # Provides 'ip' command for network interface management

    # Rust toolchain REMOVED — ~6GB (rustc+cargo+llvm), build-only.
    # Termux is edit+git only; nothing compiles here. Restore only if
    # you deliberately reverse the no-build policy.

    # Dependencies that stop npm from panicking (build-only — removable
    # if the node deps-merge never compiles native addons)
    python3
    gnumake
    gcc

    # Memory allocator fix for Android
    jemalloc
    mimalloc

    # JSON/YAML processing
    jq

    # Compression — zstd is used by build.sh (nar.zst import + the
    # per-path GHCR nix cache decompress); native so `pull` needs no
    # `nix run nixpkgs#zstd` round-trip.
    zstd

    # OCI registry client — build.sh `pull` uses oras for the per-path
    # GHCR nix cache (manifest fetch + delta blob fetch). Native so
    # `pull` skips the slow `nix run nixpkgs#oras` proot eval.
    oras

    # Secrets & crypto
    openssl
    gnupg
    sops
    age
    yq-go

    # Cloud CLIs
    gh
    flarectl
    cloudflared
    google-cloud-sdk
    oci-cli
    # awscli2 removed (~440MB) — AWS not used; gcloud + oci kept

    # Infrastructure as Code
    terraform
    # wrangler: installed via npm global in node-bins.nix (needs 3.60+ for [observability])

    # VPN & networking
    # NOTE: wireguard-tools (wg CLI) requires root — useless on Android.
    # The WireGuard Android app manages the tunnel via VPN API instead.
    # We provide a wrapper that warns and redirects to `connect`.
    (writeShellScriptBin "wg" (builtins.readFile ../scripts/wg.sh))
    # inetutils → telnet, ftp, rsh, rlogin, hostname, dnsdomainname, etc.
    # Demoted with lowPrio so iputils wins the ping/ping6/traceroute6 file
    # collisions. inetutils' ping uses SOCK_RAW + setuid() (bionic libc
    # has no setuid impl → "Function not implemented" on Termux).
    (lib.lowPrio inetutils)
    # iputils → ping (SOCK_DGRAM via IPPROTO_ICMP, no raw sockets, no
    # setuid), ping6, tracepath, traceroute6, arping, clockdiff. The
    # SOCK_DGRAM path works on Termux/Android as long as the user's
    # gid is in /proc/sys/net/ipv4/ping_group_range (Android default
    # range is wide-open). This is the same kernel path Android system
    # apps use for ping.
    iputils
    termux-am

    # getconf — POSIX sysconf utility needed by wrangler (Cloudflare Workers CLI)
    # Not included in Termux/nix-on-droid by default (normally from glibc)
    (writeShellScriptBin "getconf" (builtins.readFile ../scripts/getconf.sh))

    # Node 22 (from nixos-24.11 for Vite 7 compat: requires >=22.12)
    pkgsUnstable.nodejs_22

    # my-ai: fetch + autoPatchelf + install both my-ai and my-ai-dash.
    # Hashes live in pkgs/my-ai-hashes.json (bumped by ship-my-ai-app.yml).
    (pkgs.callPackage ../pkgs/my-ai.nix {})

    # 3. SYNC — unified sync engine (git + rclone)
    # Source: ~/git/tools/a-sync/sync.sh
    (writeShellScriptBin "sync" (builtins.readFile ../scripts/sync.sh))

    # 3b. SERVER — delegates to ~/git/front/server.sh (dev server control)
    (writeShellScriptBin "server" (builtins.readFile ../scripts/server.sh))

    # 4. CODE-SERVER (trying aggressive V8/Node fixes for Android)
    (writeShellScriptBin "code"
      (builtins.replaceStrings
        [ "@jemalloc@"        "@python3_bin@"       "@code_server_bin@"       ]
        [ "${pkgs.jemalloc}"  "${pkgs.python3}/bin" "${pkgs.code-server}/bin" ]
        (builtins.readFile ../scripts/code.sh)))

    # 5. gacp binary REMOVED (2026-08-08 audit): the fish `gacp`
    # function (add/commit/push — the documented behavior) shadows
    # any PATH binary unconditionally, so this a-sync-delegating
    # wrapper was unreachable in fish and wrong when reached.

    # 6. GCL (Git Clone shortcut)
    (writeShellScriptBin "gcl" (builtins.readFile ../scripts/gcl.sh))

    # 7. CONNECT (Unified hub: HM, mesh, git, drives, sync, servers, security)
    # Source: ~/git/tools/a-connect/connect.sh
    (writeShellScriptBin "connect" (builtins.readFile ../scripts/connect.sh))

    # 7b. sync — REMOVED: duplicate of entry 3 above (same name, same
    # source). Identical today so nix dedups, but any divergence
    # becomes a store-path collision.

    # 8. NIX-DRIFT (Version drift detection for nix flakes)
    # Source: ../nix-version-drift.sh
    (writeShellScriptBin "nix-drift"
      (builtins.replaceStrings
        [ "@nixVersionDriftSh@"     ]
        [ "${../nix-version-drift.sh}" ]
        (builtins.readFile ../scripts/nix-drift.sh)))

    # 9. CLAUDE — native-binary derivation (pkgs/claude-code), pinned
    # 2.1.226. Was pkgsUnstable.claude-code (2.1.177), but bumping the
    # whole unstable channel just to get a newer claude drags every
    # other unstable package along (100+ MiB re-downloads on the
    # phone). The local derivation upgrades claude ALONE: bump
    # `version` + `hash` in pkgs/claude-code/default.nix, switch —
    # one ~90 MB tarball, nothing else rebuilt.
    (pkgs.callPackage ../pkgs/claude-code {})

    # 10. ANT — official Anthropic CLI for the Claude Developer
    # Platform (Managed Agents, Messages, Files, ...). Released
    # 2026-04-08. Pre-built linux/arm64 Go binary from GitHub
    # releases, fetched as a content-addressed source.
    (pkgs.callPackage ../pkgs/ant {})

    # 11. YAZI — TUI file manager. From unstable (24.05's is ancient);
    # aarch64 binary comes from cache.nixos.org, nothing compiles here.
    pkgsUnstable.yazi

    # 11b. ETC-SELF-HEAL — /etc/static repair used by bash login and
    # fish init. Source: ../scripts/etc-self-heal.sh
    (writeShellScriptBin "etc-self-heal" (builtins.readFile ../scripts/etc-self-heal.sh))

    # 12. SW — bidirectional git-sync + build.sh switch as a REAL
    # BINARY. `switch` is a fish reserved word (unusable as a command
    # name) and `up` was shadowed for months by a config.local.fish
    # alias — a PATH binary sidesteps fish function machinery
    # entirely. Source: ../scripts/sw.sh
    (writeShellScriptBin "sw" (builtins.readFile ../scripts/sw.sh))

    # 12b. CLAUDE--DEBUG — one-shot claude-startup diagnostic battery
    # (env, shell-snapshot cost, headless probe, TUI probes w/ debug
    # files). Ships its log to cloud-data/logs/ AND unix/1_reports/
    # (committed+pushed) so the cloud Claude session can pull it and
    # keep the debugging loop going. Source: ../claude/assets/scripts/claude-debug.sh
    (writeShellScriptBin "claude--debug"
      (builtins.readFile ../claude/assets/scripts/claude-debug.sh))
  ];
}
