{
  description = "Nix-on-Droid Termux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-new.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-on-droid = {
      # release-24.05 hasn't moved since 2024-07-07 (effectively abandoned) —
      # its fixed-output-derivation binary pins (e.g. proot-termux-static)
      # decayed out of the substituter cache, breaking CI with
      # "path ... does not exist and cannot be created" (2026-07-03).
      # master is actively maintained and has current, fetchable pins.
      url = "github:nix-community/nix-on-droid/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-new, nixpkgs-unstable, nix-on-droid, home-manager }:
    let
      pkgsNew = import nixpkgs-new { system = "aarch64-linux"; };
      pkgsUnstable = import nixpkgs-unstable { system = "aarch64-linux"; config.allowUnfree = true; };

      # Node identity for DTK webhooks (ntfy topic = dtk-cmd-<dtkNode>).
      # Source of truth: build.json -> defaults.dtk_node. Termux can't
      # sethostname() on Android (no root) so `hostname -s` returns
      # "localhost" — useless as a topic key. This makes the identity
      # declarative + data-driven instead.
      # ./build.json is vendored into src/ by build.sh before eval — the flake
      # must reference nothing outside src/ (path: flake; a ../ ref escaping src/
      # forces nix to copy the whole 3.6GB repo and proot dies mid-copy).
      buildJson = builtins.fromJSON (builtins.readFile ./build.json);
      dtkNode = buildJson.defaults.dtk_node or "unset";

      # Build termux-am from nix-on-droid source (provides `am` for Android intents)
      termux-am = (import nixpkgs { system = "aarch64-linux"; }).callPackage
        "${nix-on-droid}/pkgs/android-integration/termux-am.nix" {};

      # Shared aliases for all shells
      sharedAliases = {
        ll = "ls -alh";
        ".." = "cd ..";
        conf = "nano ~/git/unix/bb_flakes_termux/src/flake.nix";
        up = "~/git/unix/bb_flakes_termux/build.sh";
        dtk = "sh ~/git/tools/dtk.sh";
      };
    in
    {
      nixOnDroidConfigurations.default = nix-on-droid.lib.nixOnDroidConfiguration {
        pkgs = import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; };
        modules = [
          ({ config, lib, pkgs, ... }: {
            system.stateVersion = "24.05";
            environment.etcBackupExtension = ".bak";

            # proot resolver must match the vault termux WireGuard profile DNS
            # (10.0.0.1 Hickory wg0, 1.1.1.1 fallback — see
            # vault/A0_keys/providers/wireguard/termux{,-public}/config).
            # nix-on-droid's default resolv.conf is 1.1.1.1/8.8.8.8
            # — that bypasses Hickory, so *.diegonmarcos.com resolves to the
            # PUBLIC edge instead of the wg IP and WG-only services (MCP, etc.)
            # 403. Hickory-first = wg-IP resolution.
            # NOTE: 10.1.0.1 removed 2026-07-02 — NO DNS service exists on the
            # wg-public hub (oci-analytics has no :53 listener and none is
            # declared); a dead resolver in the list only adds per-lookup
            # timeouts (broke mail-client resolution on Android).
            environment.etc."resolv.conf".text = lib.mkForce ''
              nameserver 10.0.0.1
              nameserver 1.1.1.1
            '';

            nix.extraOptions = ''
              experimental-features = nix-command flakes
              # Phone has 7GB RAM. max-jobs=2 × cores=4 = up to 8 parallel
              # compile jobs which OOM-thrashed during openssh-pinned + ncurses
              # static builds (ate 4.6GB swap). Cap at 1 job × 2 cores so big
              # native compiles finish without swap death.
              max-jobs = 1
              cores = 2
              auto-optimise-store = false
              min-free = 1073741824
              min-free-check-interval = 30
              keep-derivations = false
            '';

            time.timeZone = "Europe/Athens";

            # Global PATH and SHELL for Bash/Zsh/Fish
            environment.sessionVariables = {
              SHELL = "${pkgs.bash}/bin/bash";
              PATH = "$HOME/.node_modules/node_modules/.bin:$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH";
              NODE_PATH = "$HOME/.node_modules/node_modules";
              # DTK webhooks node identity (Android can't sethostname; see flake.nix `dtkNode`)
              DTK_NODE_NAME = dtkNode;
              # Global memory allocator fix for Android - propagates to ALL child processes
              LD_PRELOAD = "${pkgs.mimalloc}/lib/libmimalloc.so";
              MIMALLOC_PAGE_RESET = "0";
              MIMALLOC_LARGE_OS_PAGES = "0";
              MALLOC_ARENA_MAX = "2";
              # Terraform: shared plugin cache (avoid 100MB+ provider binaries per project)
              TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";
              # fish/others expect a private runtime dir; unset → "Runtime path
              # not available". Created 0700 by the home.activation below.
              XDG_RUNTIME_DIR = "$HOME/.cache/xdg-runtime";
              # Locale — en_DK.UTF-8 = ISO-8601 dates + 24h. Set at the nix-on-droid
              # env level (not home.sessionVariables) so LOCALE_ARCHIVE is already
              # in scope when LANG/LC_ALL are exported → no setlocale warning at login.
              LANG = "en_DK.UTF-8";
              LC_ALL = "en_DK.UTF-8";
              LOCALE_ARCHIVE = "${pkgs.glibcLocales}/lib/locale/locale-archive";
            };

            user.shell = "${pkgs.fish}/bin/fish";
            # This closure is built in CI, where nix-on-droid would bake
            # /etc/passwd from the RUNNER's `id -u` (1000). Pin the phone's real
            # Android app uid so getpwuid(10635) resolves → whoami + sshd client
            # (git push over SSH) work. Update if the app is reinstalled with a
            # different uid (`id -u`).
            user.uid = 10635;
            # Same CI-vs-phone mismatch for the group: the runner's `id -g` (100)
            # gets baked as pw_gid, but the Android /dev/pts nodes are owned by
            # gid 10635 and we're NOT in group 100. sshd's pty_setowner then does
            # chown(pts, 10635, 100) as non-root → EPERM → fatal → the app's
            # terminal session dies right after auth ("Auth OK but no terminal").
            # Pinning gid=10635 makes pw_gid match the pts group → no chown needed.
            user.gid = 10635;

            environment.packages = with pkgs; [
              # Nerd Fonts (for terminal icons)
              (nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; })

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
              (writeShellScriptBin "wg" (builtins.readFile ./scripts/wg.sh))
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
              (writeShellScriptBin "getconf" (builtins.readFile ./scripts/getconf.sh))

              # Node 22 (from nixos-24.11 for Vite 7 compat: requires >=22.12)
              pkgsNew.nodejs_22

              # my-ai: fetch + autoPatchelf + install both my-ai and my-ai-dash.
              # Hashes live in pkgs/my-ai-hashes.json (bumped by ship-my-ai-app.yml).
              (pkgs.callPackage ./pkgs/my-ai.nix {})

              # 3. SYNC — unified sync engine (git + rclone)
              # Source: ~/git/tools/a-sync/sync.sh
              (writeShellScriptBin "sync" (builtins.readFile ./scripts/sync.sh))

              # 3b. SERVER — delegates to ~/git/front/server.sh (dev server control)
              (writeShellScriptBin "server" (builtins.readFile ./scripts/server.sh))

              # 4. CODE-SERVER (trying aggressive V8/Node fixes for Android)
              (writeShellScriptBin "code"
                (builtins.replaceStrings
                  [ "@jemalloc@"        "@python3_bin@"       "@code_server_bin@"       ]
                  [ "${pkgs.jemalloc}"  "${pkgs.python3}/bin" "${pkgs.code-server}/bin" ]
                  (builtins.readFile ./scripts/code.sh)))

              # 5. GACP (Git Add, Commit, Push) — convenience wrapper for sync
              (writeShellScriptBin "gacp" (builtins.readFile ./scripts/gacp.sh))

              # 6. GCL (Git Clone shortcut)
              (writeShellScriptBin "gcl" (builtins.readFile ./scripts/gcl.sh))

              # 7. CONNECT (Unified hub: HM, mesh, git, drives, sync, servers, security)
              # Source: ~/git/tools/a-connect/connect.sh
              (writeShellScriptBin "connect" (builtins.readFile ./scripts/connect.sh))

              # 7b. SYNC (Rclone sync manager)
              # Source: ~/git/tools/a-sync/sync.sh
              (writeShellScriptBin "sync" (builtins.readFile ./scripts/sync.sh))

              # 8. NIX-DRIFT (Version drift detection for nix flakes)
              # Source: ./nix-version-drift.sh
              (writeShellScriptBin "nix-drift"
                (builtins.replaceStrings
                  [ "@nixVersionDriftSh@"     ]
                  [ "${./nix-version-drift.sh}" ]
                  (builtins.readFile ./scripts/nix-drift.sh)))

              # 9. CLAUDE — from nixpkgs (added to nixpkgs-unstable 2026-07).
              # Auto-updates via `build.sh update` + switch. No manual hash pins.
              pkgsUnstable.claude-code

              # 10. ANT — official Anthropic CLI for the Claude Developer
              # Platform (Managed Agents, Messages, Files, ...). Released
              # 2026-04-08. Pre-built linux/arm64 Go binary from GitHub
              # releases, fetched as a content-addressed source.
              (pkgs.callPackage ./pkgs/ant {})

              # 11. YAZI — TUI file manager. From unstable (24.05's is ancient);
              # aarch64 binary comes from cache.nixos.org, nothing compiles here.
              pkgsUnstable.yazi

              # 12. CLAUDE--DEBUG — one-shot claude-startup diagnostic battery
              # (env, shell-snapshot cost, headless probe, TUI probes w/ debug
              # files). Ships its log to cloud-data/logs/ AND unix/1_reports/
              # (committed+pushed) so the cloud Claude session can pull it and
              # keep the debugging loop going. Source: ./scripts/claude-debug.sh
              (writeShellScriptBin "claude--debug"
                (builtins.readFile ./scripts/claude-debug.sh))
            ];

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { config, pkgs, lib, ... }: {
              _module.args.nodejs = pkgsNew.nodejs_22;
              # wstunnel 7.x (Rust) lives in pkgsUnstable. The old wstunnel 0.5.x
              # in pinned nixos-24.05 is Haskell and pulls connection-0.3.1 which
              # is marked broken upstream — blocking every home-manager switch.
              _module.args.wstunnel = pkgsUnstable.wstunnel;
              imports = [
                ./modules/common.nix
                ./modules/packages.nix
                ./modules/curl-wget-wrapper.nix
                ./modules/node-npm-deps.nix
                ./modules/node-bins.nix
                ./modules/httpd-web-server-json-md-eruda
                ./modules/cloud-ide-sshd
                ./modules/wireguard.nix
                ./modules/wireguard-wstunnel.nix
              ];
              home.stateVersion = "24.05";

              # This runs BEFORE packages are linked
              home.activation.createUsrLib = lib.hm.dag.entryBefore ["writeBoundary"] ''
                $DRY_RUN_CMD mkdir -p /data/data/com.termux.nix/files/usr/lib
                $DRY_RUN_CMD chmod 755 /data/data/com.termux.nix/files/usr/lib
              '';

              # DNS self-heal — environment.etc points /etc/resolv.conf at
              # /etc/static/resolv.conf (a store path). If that store-etc lacks
              # resolv.conf (an older generation, or a partial activation) the
              # symlink DANGLES → the system resolver reads nothing → DNS dies →
              # and you then CANNOT `nix-on-droid switch` to fix it because
              # fetching needs DNS. Deadlock. `test -s` follows the symlink and is
              # false when it dangles or is empty; only then do we drop the dead
              # link and write a REAL resolver file (matches the declared servers,
              # cannot dangle). No-op on a healthy system.
              home.activation.resolvConfSelfHeal = lib.hm.dag.entryAfter ["linkGeneration"] ''
                if [ ! -s /etc/resolv.conf ]; then
                  $DRY_RUN_CMD rm -f /etc/resolv.conf 2>/dev/null || true
                  $DRY_RUN_CMD sh -c 'printf "nameserver 10.0.0.1\nnameserver 1.1.1.1\n" > /etc/resolv.conf' 2>/dev/null || true
                  $DRY_RUN_CMD chmod 644 /etc/resolv.conf 2>/dev/null || true
                fi
              '';

              # Create Unison target folder on Android storage
              home.activation.createUnisonTarget = lib.hm.dag.entryBefore ["writeBoundary"] ''
                $DRY_RUN_CMD mkdir -p "/storage/emulated/0/Mounts/Termux-Home"
              '';

              home.activation.xdgRuntimeDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                mkdir -p "$HOME/.cache/xdg-runtime"
                chmod 700 "$HOME/.cache/xdg-runtime"
              '';

              # Initialize $HOME as minimal git repo so Claude Code uses git ls-files (instant)
              # instead of ripgrep fallback (97s timeout scanning all of $HOME)
              home.activation.initHomeGit = lib.hm.dag.entryAfter ["linkGeneration"] ''
                if [ ! -d "$HOME/.git" ]; then
                  $DRY_RUN_CMD ${pkgs.git}/bin/git init "$HOME" 2>/dev/null
                fi
                # Ensure .gitignore is tracked (it's a nix-managed symlink)
                $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$HOME" add -f .gitignore 2>/dev/null || true
              '';

              # Symlink nix-profile bins into Termux usr/bin so non-shell processes
              # (Claude Code, Android app launchers) can find nix-installed tools
              # without relying on shell init PATH expansion.
              home.activation.linkNixBinsToTermux = lib.hm.dag.entryAfter ["linkGeneration"] ''
                TERMUX_BIN="/data/data/com.termux.nix/files/usr/bin"
                NIX_BIN="$HOME/.nix-profile/bin"
                if [ -d "$TERMUX_BIN" ] && [ -d "$NIX_BIN" ]; then
                  for f in "$NIX_BIN"/*; do
                    name="$(basename "$f")"
                    target="$TERMUX_BIN/$name"
                    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
                      $DRY_RUN_CMD ln -sf "$f" "$target"
                    fi
                  done
                fi
              '';

              # Termux font — JetBrainsMono Nerd Font
              home.file.".termux/font.ttf".source =
                "${pkgs.nerdfonts.override { fonts = [ "JetBrainsMono" ]; }}/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf";

              # claude-fix — diagnose & repair a shadowed/non-starting `claude`
              # (stale npm shims / leftover claude-tty wrappers / fish functions).
              # Full xtrace log lands in ~/claude-fix.log. See scripts/claude-fix.sh.
              home.file."claude-fix.sh" = {
                source = ./scripts/claude-fix.sh;
                executable = true;
              };
              # One-time sweep of the 2026-08 deepseek debugging leftovers
              # (claude.bin copy, claude-tty wrapper, pre-nix npm claude in the
              # Termux prefix). Idempotent — prints "already gone" after the
              # first run. Log: ~/deepseek-cleanup.log.
              home.file."deepseek-cleanup.sh" = {
                source = ./scripts/deepseek-cleanup.sh;
                executable = true;
              };

              # Claude Code master context + MCP server config
              # CLAUDE.md is now a 1-char stub — all principles/reference content moved to
              # cloud-principles-ai-plugin (hooks-fragments/*.md, injected via SessionStart/
              # UserPromptSubmit hooks), shared with ba_flakes_desktop's cloud-marketplace
              # (one source of truth — see that flake's common.nix for the full rationale).
              home.file.".claude/CLAUDE.md".text = "\n";
              home.file.".claude/mcp.json.tpl".source = ./modules/dotfiles/claude/mcp.json.tpl;
              home.file.".claude/secrets.yaml".source = ./modules/dotfiles/claude/secrets.yaml;
              home.file.".claude/statusline-command.sh" = {
                source = ./modules/dotfiles/claude/statusline-command.sh;
                executable = true;
              };
              # Agent fleet manifest (explore/build/review/ops, all pinned model:sonnet)
              # — same roster as desktop (ba_flakes_desktop dotfiles/claude/agents).
              home.file.".claude/agents" = {
                source = ./modules/dotfiles/claude/agents;
                recursive = true;
              };
              # Plugin/MCP status for the statusline + claude-superset banner (data-driven).
              home.file.".claude/claude-plugins.json".source = ./modules/dotfiles/claude/claude-plugins.json;
              home.file.".claude/claude-plugins-status.sh" = {
                source = ./modules/dotfiles/claude/claude-plugins-status.sh;
                executable = true;
              };
              home.file.".claude/claude-mcp-status.sh" = {
                source = ./modules/dotfiles/claude/claude-mcp-status.sh;
                executable = true;
              };
              # Vendored locally — the flake must stay self-contained (path: flake,
              # no cross-repo refs). Refreshed from the da_my-ai statusline SoT.
              home.file.".claude/claude-hooks-status.sh" = {
                source = ./modules/dotfiles/claude/claude-hooks-status.sh;
                executable = true;
              };
              home.file.".claude/claude-pricing.json".source =
                ./modules/dotfiles/claude/claude-pricing.json;
              # cloud-marketplace — SHARED with ba_flakes_desktop (one source of truth,
              # not a copy): local Claude Code plugin marketplace holding
              # cloud-principles-ai-plugin (the data-driven hook engine — replaces the
              # old tier-based a-/b-/c- hook scripts above) and ponytail. See
              # ba_flakes_desktop/src/modules/common.nix for the full rationale.
              home.file.".claude/cloud-marketplace".source =
                ./modules/dotfiles/claude/cloud-marketplace;
              # settings.json deployed as a writable real file (not a nix-store symlink)
              # so that runtime commands (/effort, /model, /fast) can persist their writes.
              # Source is authoritative: each switch resets runtime prefs back to declared values.
              home.activation.claudeSettingsWritable = lib.hm.dag.entryAfter ["linkGeneration"] ''
                _src=${./modules/dotfiles/claude/settings.json}
                _dst="$HOME/.claude/settings.json"
                [ -L "$_dst" ] && rm "$_dst"
                ${pkgs.coreutils}/bin/install -m 600 "$_src" "$_dst"
              '';
              # Register cloud-marketplace as a plugin marketplace (idempotent CLI call
              # from a nix-committed activation — same pattern as
              # ba_flakes_desktop's claudeMarketplace). claude-code is a real nix
              # derivation on PATH here (pkgsUnstable.claude-code), not a curl-installed binary.
              home.activation.claudeMarketplace = lib.hm.dag.entryAfter [ "claudeSettingsWritable" ] ''
                MARKETPLACE_DIR="$HOME/.claude/cloud-marketplace"
                JQ="${pkgs.jq}/bin/jq"
                # Explicit path — activation runs with a minimal PATH that does
                # NOT include ~/.nix-profile/bin, so `command -v claude` failed
                # here and the marketplace silently never registered.
                CLAUDE="$HOME/.nix-profile/bin/claude"
                if [ -x "$CLAUDE" ] && [ -d "$MARKETPLACE_DIR" ]; then
                  $DRY_RUN_CMD "$CLAUDE" plugin marketplace add "$MARKETPLACE_DIR" >/dev/null 2>&1 || true
                  echo "[claude-marketplace] cloud-marketplace registered (enabledPlugins declared in settings.json)"
                  # Durable installPath materialization (see ba_flakes_desktop/common.nix
                  # for the rationale): Claude Code's /plugin loader validates
                  # plugins/cache/<marketplace>/<plugin>/<version>, which nothing
                  # populates for a directory-source marketplace — so it reports
                  # "cannot find the hooks" after a store-swap. Symlink each
                  # installPath into the store-backed marketplace dir. Data-driven:
                  # plugin names from marketplace.json, version from each plugin.json.
                  CACHE_DIR="$HOME/.claude/plugins/cache/cloud-marketplace"
                  MKT_JSON="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
                  if [ -f "$MKT_JSON" ]; then
                    for P in $("$JQ" -r '.plugins[].name' "$MKT_JSON" 2>/dev/null); do
                      VER=$("$JQ" -r '.version // "1.0.0"' "$MARKETPLACE_DIR/$P/.claude-plugin/plugin.json" 2>/dev/null || echo "1.0.0")
                      DEST="$CACHE_DIR/$P/$VER"
                      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$CACHE_DIR/$P"
                      [ -e "$DEST" ] && [ ! -L "$DEST" ] && $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$DEST"
                      $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$MARKETPLACE_DIR/$P" "$DEST"
                      echo "[claude-marketplace] materialized $P@$VER -> cache installPath"
                    done
                  fi
                else
                  echo "[claude-marketplace] WARNING: skipping — missing: $([ -x "$CLAUDE" ] || echo "$CLAUDE ")$([ -d "$MARKETPLACE_DIR" ] || echo "$MARKETPLACE_DIR")"
                fi
              '';
              # NO LOOSE SKILLS — same design as ba_flakes_desktop. ~/.claude/skills/
              # must stay empty; every skill ships as a plugin (skill-<name>-plugin)
              # in the SHARED cloud-marketplace, enabled declaratively via
              # settings.json enabledPlugins, and unloads with its plugin.
              #   claude-api      -> cloud-marketplace/skill-claude-api-plugin
              #   frontend-design -> frontend-design@claude-plugins-official (already
              #                      enabled in settings.json; the vendored skill copy
              #                      was a duplicate and was removed)

              # ── Writable dotfiles (see ba_flakes_desktop/common.nix for rationale) ──
              # Swap each store-backed HM symlink for a writable copy right after
              # linkGeneration so deployed files are editable for imperative tests;
              # the next switch re-links then re-copies (declarative always wins).
              # Data-driven from config.home.file (xdg.configFile feeds into it).
              home.activation.unfreezeHmFiles =
                let
                  _writableTargets = pkgs.writeText "hm-writable-targets"
                    (lib.concatMapStringsSep "\n" (f: f.target) (lib.attrValues config.home.file));
                in lib.hm.dag.entryAfter [ "linkGeneration" ] ''
                  while IFS= read -r _rel; do
                    [ -n "$_rel" ] || continue
                    _t="$HOME/$_rel"
                    [ -L "$_t" ] || continue
                    _r="$(${pkgs.coreutils}/bin/readlink -f "$_t" 2>/dev/null)"
                    [ -n "$_r" ] && [ -e "$_r" ] || continue
                    case "$_r" in /nix/store/*) ;; *) continue ;; esac
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$_t"
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -RL "$_r" "$_t"
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod -R u+w "$_t"
                  done < ${_writableTargets}
                '';

              home.file.".rgignore".source = ./modules/dotfiles/claude/rgignore;

              # Gemini CLI configuration + MCP server config
              home.file.".gemini/settings.json.tpl".source = ./modules/dotfiles/gemini/settings.json.tpl;

              # MCP secrets: decrypt secrets.yaml → awk subst ''${VAR} → ~/.mcp.json
              # Mimics Docker env_file + init.sh pattern using awk index() (literal, no regex)
              home.activation.mcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
                SOPS="$HOME/.nix-profile/bin/sops"
                TPL="$HOME/.claude/mcp.json.tpl"
                SECRETS_YAML="$HOME/.claude/secrets.yaml"
                OUT="$HOME/.mcp.json"
                YQ="${pkgs.yq-go}/bin/yq"
                AWK="${pkgs.gawk}/bin/awk"

                # Every cp below must rm the target first + chmod after: cp from
                # the store template preserves its 0444 mode, so a fallback run
                # that skipped chmod left ~/.mcp.json read-only and every later
                # switch died with "cp: cannot create regular file: Permission
                # denied" (seen 2026-08-08).
                if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
                  echo "[mcp-secrets] WARNING: sops/secrets/template not found, copying template as-is"
                  [ -f "$TPL" ] && { rm -f "$OUT"; cp "$TPL" "$OUT"; chmod 600 "$OUT"; }
                  exit 0
                fi

                # Decrypt secrets.yaml (same as cloud/ _engine.sh pattern)
                DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
                if [ -z "$DECRYPTED" ]; then
                  echo "[mcp-secrets] WARNING: failed to decrypt secrets.yaml"
                  rm -f "$OUT"; cp "$TPL" "$OUT"; chmod 600 "$OUT"
                  exit 0
                fi

                # Copy template to output
                rm -f "$OUT"; cp "$TPL" "$OUT"; chmod 600 "$OUT"

                # Extract ''${VAR} placeholders using awk (no sed, no regex on secrets)
                VARS=$($AWK '{
                  s = $0
                  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
                    v = substr(s, RSTART+2, RLENGTH-3)
                    print v
                    s = substr(s, RSTART+RLENGTH)
                  }
                }' "$OUT" | sort -u) || true

                # awk index() substitution — literal string match, no regex
                # Same proven pattern as Authelia init.sh and cloud/ _engine.sh
                for _var in $VARS; do
                  _val=$(printf '%s' "$DECRYPTED" | "$YQ" -r ".[\"$_var\"]" 2>/dev/null) || true
                  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
                    echo "[mcp-secrets] WARNING: $_var not found in secrets — leaving placeholder"
                    continue
                  fi
                  _pat="\''${''${_var}}"
                  $AWK -v pat="$_pat" -v rep="$_val" '{
                    while (i = index($0, pat)) {
                      $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
                    }
                    print
                  }' "$OUT" > "$OUT.tmp"
                  mv "$OUT.tmp" "$OUT"
                done

                chmod 600 "$OUT"
                echo "[mcp-secrets] ~/.mcp.json templated ($(echo $VARS | wc -w) vars substituted)"
              '';

              # Gemini CLI: decrypt secrets.yaml → awk subst ''${VAR} → ~/.gemini/settings.json
              home.activation.geminiMcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
                SOPS="$HOME/.nix-profile/bin/sops"
                TPL="$HOME/.gemini/settings.json.tpl"
                SECRETS_YAML="$HOME/.claude/secrets.yaml"
                OUT="$HOME/.gemini/settings.json"
                YQ="${pkgs.yq-go}/bin/yq"
                AWK="${pkgs.gawk}/bin/awk"

                if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
                  echo "[gemini-mcp] WARNING: sops/secrets/template not found, copying template as-is"
                  [ -f "$TPL" ] && cp "$TPL" "$OUT"
                  exit 0
                fi

                DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
                if [ -z "$DECRYPTED" ]; then
                  echo "[gemini-mcp] WARNING: failed to decrypt secrets.yaml"
                  cp "$TPL" "$OUT"
                  exit 0
                fi

                cp "$TPL" "$OUT"

                VARS=$($AWK '{
                  s = $0
                  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
                    v = substr(s, RSTART+2, RLENGTH-3)
                    print v
                    s = substr(s, RSTART+RLENGTH)
                  }
                }' "$OUT" | sort -u) || true

                for _var in $VARS; do
                  _val=$(printf '%s' "$DECRYPTED" | "$YQ" -r ".[\"$_var\"]" 2>/dev/null) || true
                  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
                    echo "[gemini-mcp] WARNING: $_var not found in secrets — leaving placeholder"
                    continue
                  fi
                  _pat="\''${''${_var}}"
                  $AWK -v pat="$_pat" -v rep="$_val" '{
                    while (i = index($0, pat)) {
                      $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
                    }
                    print
                  }' "$OUT" > "$OUT.tmp"
                  mv "$OUT.tmp" "$OUT"
                done

                chmod 600 "$OUT"
                echo "[gemini-mcp] ~/.gemini/settings.json templated ($(echo $VARS | wc -w) vars substituted)"
              '';

              # Minimal .gitignore so $HOME is a git repo (ignore everything)
              # This makes Claude Code use `git ls-files` (instant) instead of ripgrep (97s timeout)
              home.file.".gitignore".text = "*";

              # Unison profile for bidirectional sync
              home.file.".unison/termux-home.prf".text = ''
                # Bidirectional sync: Termux home <-> Android storage
                root = /data/data/com.termux.nix/files/home
                root = /storage/emulated/0/Mounts/Termux-Home

                # Android storage compatibility
                perms = 0
                dontchmod = true
                links = false

                # Prefer newer files on conflict
                prefer = newer

                # Auto-accept non-conflicting changes
                auto = true
                batch = true

                # Only sync specific folders (avoid system files)
                path = nix-home-manager
                path = desktop
              '';

              programs.bash = {
                enable = true;
                shellAliases = sharedAliases;
                profileExtra = ''
                  export PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"
                  # /etc self-heal — a FAILED nix-on-droid switch relinks
                  # /etc/static to the new generation's etc mid-activation, then
                  # aborts before committing; that orphaned etc is later GC'd, so
                  # /etc/{passwd,resolv.conf,group} dangle → no SSH/DNS → and you
                  # can't switch to fix it (activation needs a working /etc).
                  # Repair from the LIVE, GC-rooted generation etc. Declarative,
                  # runs every login, no-op when healthy.
                  if [ ! -e /etc/static/passwd ]; then
                    _ge=$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/nix-on-droid/etc 2>/dev/null)
                    [ -n "$_ge" ] && [ -e "$_ge/passwd" ] && ${pkgs.coreutils}/bin/ln -sfn "$_ge" /etc/static 2>/dev/null || true
                  fi
                '';
              };

              programs.zsh = {
                enable = true;
                shellAliases = sharedAliases;
              };

              programs.fish = {
                enable = true;
                shellAliases = sharedAliases;
                interactiveShellInit = ''

                  # /etc self-heal — repair a dangling /etc/static (left by a
                  # failed switch whose orphaned etc got GC'd) from the live,
                  # GC-rooted generation etc. See programs.bash.profileExtra for
                  # the full rationale. Declarative, no-op when healthy.
                  if not test -e /etc/static/passwd
                    set -l _ge (${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/nix-on-droid/etc 2>/dev/null)
                    if test -n "$_ge"; and test -e "$_ge/passwd"
                      ${pkgs.coreutils}/bin/ln -sfn "$_ge" /etc/static 2>/dev/null
                    end
                  end

                  # NOTE: sshd auto-start lives in modules/cloud-ide-sshd (`cloud-ide-sshd start`).
                  # The previous block here referenced ~/.ssh/sshd_config which is never
                  # created — it failed silently and hid real startup errors. Removed.

                  # Auto-start httpd-web-server-json-md-eruda (on-demand wrapper).
                  # If the runit service (sv-enable'd by the nix module) is
                  # already supervising it in the background, this is a no-op
                  # (is_running check inside the wrapper finds its PID file).
                  set -g __httpd_port 8000
                  if command -q httpd-web-server-json-md-eruda
                    httpd-web-server-json-md-eruda start >/dev/null 2>&1
                    set -g __httpd_pid (cat ~/.cache/httpd-web-server-json-md-eruda.pid 2>/dev/null)
                  end

                  # FZF configuration
                  set -gx FZF_DEFAULT_OPTS "--height 40% --layout=reverse --border"

                  # FZF key bindings for fish
                  function fzf_file
                    set -l result (fzf --preview 'head -100 {}')
                    if test -n "$result"
                      commandline -i "$result"
                    end
                    commandline -f repaint
                  end

                  function fzf_history
                    set -l result (history | fzf --no-sort)
                    if test -n "$result"
                      commandline -r "$result"
                    end
                    commandline -f repaint
                  end

                  function fzf_cd
                    set -l result (find . -type d 2>/dev/null | fzf)
                    if test -n "$result"
                      cd "$result"
                    end
                    commandline -f repaint
                  end

                  # Bind Ctrl+T for file, Ctrl+R for history, Alt+C for cd
                  bind \ct fzf_file
                  bind \cr fzf_history
                  bind \ec fzf_cd


                  # Greeting is fish_greeting in modules/programs/shells/fish/functions/fish_greeting.fish (wired via fish.nix)
                '';
              };
            };
          })
        ];
      };

      # ── termux-cache-image: LAYERED image of the nix-on-droid closure ──
      # One layer per store path (dockerTools.buildLayeredImage) → skopeo
      # (no Docker daemon needed on Android — see build.sh's
      # ghcr_pull_layered_skopeo) skips unchanged layers, so `build.sh pull`
      # fetches only the store paths that actually changed instead of
      # re-downloading the whole multi-GB nar. Pushed to GHCR by the CI
      # export step (GHCR_PUSH=1); consumed by `cmd_pull` (the nar.zst path
      # is kept as the fallback). Mirrors ba_flakes_desktop's hm-cache-image.
      packages.aarch64-linux.termux-cache-image = pkgsNew.dockerTools.buildLayeredImage {
        name = "unix-termux-cache";
        tag = "latest";
        maxLayers = 120;
        contents = [ self.nixOnDroidConfigurations.default.activationPackage ];
        config.Labels = {
          "org.opencontainers.image.description" = "Termux (nix-on-droid) activation closure as layered store paths (incremental GHCR cache).";
          "org.opencontainers.image.source" = "https://github.com/diegonmarcos/unix";
        };
      };
    };
}
