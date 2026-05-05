{
  description = "Nix-on-Droid Termux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-new.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/release-24.05";
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
      pkgsUnstable = import nixpkgs-unstable { system = "aarch64-linux"; };

      # Node identity for DTK webhooks (ntfy topic = dtk-cmd-<dtkNode>).
      # Source of truth: build.json -> defaults.dtk_node. Termux can't
      # sethostname() on Android (no root) so `hostname -s` returns
      # "localhost" — useless as a topic key. This makes the identity
      # declarative + data-driven instead.
      buildJson = builtins.fromJSON (builtins.readFile ../build.json);
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
            };

            user.shell = "${pkgs.fish}/bin/fish";

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

              # Rust toolchain (unstable for edition2024 support, 1.85+)
              pkgsUnstable.rustc
              pkgsUnstable.cargo

              # Dependencies that stop npm from panicking
              python3
              gnumake
              gcc

              # Memory allocator fix for Android
              jemalloc
              mimalloc

              # JSON/YAML processing
              jq

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
              awscli2

              # Infrastructure as Code
              terraform
              # wrangler: installed via npm global in node-bins.nix (needs 3.60+ for [observability])

              # VPN & networking
              # NOTE: wireguard-tools (wg CLI) requires root — useless on Android.
              # The WireGuard Android app manages the tunnel via VPN API instead.
              # We provide a wrapper that warns and redirects to `connect`.
              (writeShellScriptBin "wg" ''
                echo ""
                echo "  THIS IS A ROOTLESS ANDROID!"
                echo "  You should NEVER try to check WireGuard connection using wg!"
                echo ""
                echo "  Use the 'connect' command instead:"
                echo "    connect status       — unified dashboard"
                echo "    connect flex-status  — OCI VM status"
                echo "    connect mount-all-vm — mount VMs via SSHFS"
                echo "    connect logs | jq .mesh — mesh JSON data"
                echo ""
              '')
              inetutils
              termux-am

              # getconf — POSIX sysconf utility needed by wrangler (Cloudflare Workers CLI)
              # Not included in Termux/nix-on-droid by default (normally from glibc)
              (writeShellScriptBin "getconf" ''
                case "$1" in
                  LONG_BIT)       echo 64 ;;
                  PAGE_SIZE)      echo 4096 ;;
                  _NPROCESSORS_ONLN) nproc 2>/dev/null || echo 1 ;;
                  *)              echo "" ;;
                esac
              '')

              # Node 22 (from nixos-24.11 for Vite 7 compat: requires >=22.12)
              pkgsNew.nodejs_22

              # claude family — every wrapper has the SAME failure-mode safety:
              # try native nix-store binary first, on ANY failure (missing,
              # SIGSEGV, exit≠0 from libc init, etc.) fall through to
              # claude-rescue's 12-fallback chain. This is intentional — the
              # phone is unreliable enough that a single-path wrapper is
              # guaranteed to fail eventually, and the user shouldn't have to
              # remember which command to run when it does.
              #
              # NOTE: NODE_OPTIONS is dropped — claude is a compiled native
              # binary, not Node.js. MALLOC_ARENA_MAX still applies (libc).

              (writeShellScriptBin "claude-termux" ''
                # Conservative malloc tuning for phone RAM.
                export MALLOC_ARENA_MAX=2

                # Sweep stale orphans before launching (see claude-malloc).
                command -v claude-orphan-sweep >/dev/null 2>&1 \
                  && claude-orphan-sweep >/dev/null 2>&1 || true

                _bin="$HOME/.nix-profile/bin/claude"
                if [ -x "$_bin" ]; then
                  # Same supervision as claude-malloc (setpriv --pdeathsig +
                  # tini -s, synchronous foreground). See claude-malloc for the
                  # full rationale.
                  ${pkgs.util-linux}/bin/setpriv --pdeathsig TERM \
                    ${pkgs.tini}/bin/tini -s -- "$_bin" "$@"
                  _rc=$?
                  # exit codes 0–125 are user-meaningful. 126/127 = exec
                  # failure (interpreter/permission). 137/139 = SIGKILL/SEGV.
                  case "$_rc" in
                    126|127|137|139) ;;   # fall through to rescue
                    *) exit "$_rc" ;;
                  esac
                fi
                echo "[claude-termux] native exec failed — trying rescue chain..." >&2
                exec sh "$HOME/git/tools/5-infos/claude-rescue/claude-rescue.sh" "$@"
              '')

              (writeShellScriptBin "claude-malloc" ''
                # Max-isolation: tight malloc arenas + dedicated TMPDIR.
                export MALLOC_ARENA_MAX=2
                export CLAUDE_TMP="$HOME/tmp/claude"
                mkdir -p "$CLAUDE_TMP"
                export TMPDIR="$CLAUDE_TMP"

                # Sweep stale orphans from previous Android-OOM-killed sessions
                # before launching, so node/MCP zombies don't pile up over time.
                command -v claude-orphan-sweep >/dev/null 2>&1 \
                  && claude-orphan-sweep >/dev/null 2>&1 || true

                _bin="$HOME/.nix-profile/bin/claude"
                if [ -x "$_bin" ]; then
                  # Process supervision (countermeasure to lmkd / parent-shell exits):
                  #   setpriv --pdeathsig TERM : if THIS wrapper dies (any signal
                  #                              except SIGKILL), kernel SIGTERMs
                  #                              tini → tini cleans up claude tree.
                  #   tini -s                  : subreaper + zombie reaper. Signals
                  #                              from the terminal pgroup reach claude
                  #                              naturally (no -g, no &, no trap),
                  #                              so the interactive TUI keeps the
                  #                              controlling terminal — Ctrl-C, etc.
                  # SIGKILL on this wrapper is uncatchable (Android lmkd hard kill);
                  # the orphan-sweep call above mops up survivors at next launch.
                  ${pkgs.util-linux}/bin/setpriv --pdeathsig TERM \
                    ${pkgs.tini}/bin/tini -s -- "$_bin" "$@"
                  _rc=$?
                  case "$_rc" in
                    126|127|137|139) ;;   # exec/signal failure → rescue
                    *) exit "$_rc" ;;
                  esac
                fi
                echo "[claude-malloc] native exec failed — trying rescue chain..." >&2
                exec sh "$HOME/git/tools/5-infos/claude-rescue/claude-rescue.sh" "$@"
              '')

              # claude-rescue: delegates to tools/5-infos/claude-rescue/
              # (12-fallback chain). The flake-side wrapper is intentionally
              # thin so the rescue logic has ONE home.
              (writeShellScriptBin "claude-rescue" ''
                exec sh "$HOME/git/tools/5-infos/claude-rescue/claude-rescue.sh" "$@"
              '')

              # claude-orphan-sweep: reap stale claude/tini orphans left over
              # from a previous SIGKILL'd session (Android lmkd hard kills are
              # uncatchable; their children get reparented to PID 1 and just
              # accumulate). Targets PPID=1 ONLY — active sessions parented by
              # a fish/bash are never touched. Called automatically at the
              # start of each claude-malloc / claude-termux launch.
              (writeShellScriptBin "claude-orphan-sweep" ''
                set -u
                swept=0
                _kill() {
                  local sig=$1 pid=$2 sid=$3
                  if [ -n "$sid" ] && [ "$sid" -gt 1 ] 2>/dev/null; then
                    kill -"$sig" -- -"$sid" 2>/dev/null || true
                  else
                    kill -"$sig" "$pid" 2>/dev/null || true
                  fi
                }
                for proc in /proc/[0-9]*; do
                  pid=''${proc##*/}
                  [ -r "$proc/status" ] || continue
                  ppid=$(${pkgs.gawk}/bin/awk '/^PPid:/ {print $2}' "$proc/status" 2>/dev/null) || continue
                  [ "$ppid" = "1" ] || continue
                  comm=$(cat "$proc/comm" 2>/dev/null) || continue
                  case "$comm" in
                    claude|claude-malloc|claude-termux|tini)
                      sid=$(${pkgs.gawk}/bin/awk '{print $6}' "$proc/stat" 2>/dev/null)
                      _kill TERM "$pid" "$sid"
                      swept=$((swept+1))
                      ;;
                  esac
                done
                if [ "$swept" -gt 0 ]; then
                  sleep 2
                  for proc in /proc/[0-9]*; do
                    pid=''${proc##*/}
                    [ -r "$proc/status" ] || continue
                    ppid=$(${pkgs.gawk}/bin/awk '/^PPid:/ {print $2}' "$proc/status" 2>/dev/null) || continue
                    [ "$ppid" = "1" ] || continue
                    comm=$(cat "$proc/comm" 2>/dev/null) || continue
                    case "$comm" in
                      claude|claude-malloc|claude-termux|tini)
                        sid=$(${pkgs.gawk}/bin/awk '{print $6}' "$proc/stat" 2>/dev/null)
                        _kill KILL "$pid" "$sid"
                        ;;
                    esac
                  done
                fi
                echo "claude-orphan-sweep: $swept process(es) reaped" >&2
              '')

              # 3. SYNC — unified sync engine (git + rclone)
              # Source: ~/git/tools/a-sync/sync.sh
              (writeShellScriptBin "sync" ''
                exec "$HOME/git/tools/a-sync/sync.sh" "$@"
              '')

              # 3b. SERVER — delegates to ~/git/front/server.sh (dev server control)
              (writeShellScriptBin "server" ''
                exec "$HOME/git/front/server.sh" "$@"
              '')

              # 4. CODE-SERVER (trying aggressive V8/Node fixes for Android)
              (writeShellScriptBin "code" ''
                # Force jemalloc for this process tree
                export LD_PRELOAD="${pkgs.jemalloc}/lib/libjemalloc.so"

                # Aggressive Node/V8 settings to prevent crashes
                export NODE_OPTIONS="--max-old-space-size=256 --v8-pool-size=1"
                export UV_THREADPOOL_SIZE=1
                export VSCODE_DISABLE_FILE_WATCHER=1

                # Disable features that cause issues on Android
                export ELECTRON_DISABLE_SANDBOX=1
                export ELECTRON_NO_ATTACH_CONSOLE=1

                # Colors
                C_RESET="\033[0m"
                C_CYAN="\033[0;36m"
                C_GREEN="\033[0;32m"
                C_YELLOW="\033[0;33m"
                C_RED="\033[0;31m"
                C_MAGENTA="\033[0;35m"
                C_BLUE="\033[0;34m"

                LOG_FILE="$HOME/.cache/code-server.log"
                PID_FILE="$HOME/.cache/code-server.pid"

                get_lan_ip() {
                  ${pkgs.python3}/bin/python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "<no-network>"
                }

                is_running() {
                  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
                }

                case "''${1:-}" in
                  local)
                    if is_running; then
                      printf "''${C_YELLOW}code-server already running (PID: $(cat "$PID_FILE"))''${C_RESET}\n"
                      exit 0
                    fi
                    printf "''${C_CYAN}Starting code-server on localhost:8080...''${C_RESET}\n"
                    mkdir -p "$(dirname "$LOG_FILE")"
                    nohup ${pkgs.code-server}/bin/code-server --bind-addr 127.0.0.1:8080 --auth none --disable-workspace-trust --disable-telemetry > "$LOG_FILE" 2>&1 &
                    echo $! > "$PID_FILE"
                    sleep 1
                    if is_running; then
                      printf "''${C_GREEN}Started on http://127.0.0.1:8080''${C_RESET}\n"
                    else
                      printf "''${C_RED}Failed to start. Check $LOG_FILE''${C_RESET}\n"
                    fi
                    ;;
                  lan)
                    if is_running; then
                      printf "''${C_YELLOW}code-server already running (PID: $(cat "$PID_FILE"))''${C_RESET}\n"
                      exit 0
                    fi
                    LAN_IP=$(get_lan_ip)
                    printf "''${C_CYAN}Starting code-server on LAN (daemon)...''${C_RESET}\n"
                    mkdir -p "$(dirname "$LOG_FILE")"
                    nohup ${pkgs.code-server}/bin/code-server --bind-addr 0.0.0.0:8080 --disable-workspace-trust --disable-telemetry > "$LOG_FILE" 2>&1 &
                    echo $! > "$PID_FILE"
                    sleep 1
                    if is_running; then
                      printf "''${C_GREEN}Started on http://$LAN_IP:8080''${C_RESET}\n"
                      printf "''${C_MAGENTA}Password:''${C_RESET} $(grep "^password:" ~/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo 'not set')\n"
                    else
                      printf "''${C_RED}Failed to start. Check $LOG_FILE''${C_RESET}\n"
                    fi
                    ;;
                  stop)
                    printf "''${C_YELLOW}Stopping code-server...''${C_RESET}\n"
                    if is_running; then
                      kill "$(cat "$PID_FILE")" 2>/dev/null
                      rm -f "$PID_FILE"
                    fi
                    ps aux 2>/dev/null | grep "code-server" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
                    sleep 1
                    printf "''${C_GREEN}Stopped.''${C_RESET}\n"
                    ;;
                  log)
                    if [ -f "$LOG_FILE" ]; then
                      tail -50 "$LOG_FILE"
                    else
                      printf "''${C_RED}No log file found''${C_RESET}\n"
                    fi
                    ;;
                  *)
                    LAN_IP=$(get_lan_ip)
                    printf "''${C_CYAN}=== code-server ===''${C_RESET}\n"
                    if is_running; then
                      printf "''${C_GREEN}RUNNING''${C_RESET} (PID: $(cat "$PID_FILE"))\n"
                      printf "  Local: ''${C_CYAN}http://127.0.0.1:8080''${C_RESET}\n"
                      printf "  LAN:   ''${C_CYAN}http://$LAN_IP:8080''${C_RESET}\n"
                    else
                      printf "''${C_RED}STOPPED''${C_RESET}\n"
                    fi
                    echo ""
                    printf "''${C_YELLOW}Commands:''${C_RESET}\n"
                    printf "  ''${C_BLUE}code local''${C_RESET}   Start on localhost (daemon)\n"
                    printf "  ''${C_BLUE}code lan''${C_RESET}     Start on LAN (daemon)\n"
                    printf "  ''${C_BLUE}code stop''${C_RESET}    Stop code-server\n"
                    printf "  ''${C_BLUE}code log''${C_RESET}     Show recent logs\n"
                    echo ""
                    printf "''${C_MAGENTA}Password:''${C_RESET} $(grep "^password:" ~/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo 'not set')\n"
                    echo ""
                    printf "''${C_RED}Note:''${C_RESET} Terminal/extensions may crash on Android.\n"
                    printf "       Access from another device for best experience.\n"
                    ;;
                esac
              '')

              # 5. GACP (Git Add, Commit, Push) — convenience wrapper for sync
              (writeShellScriptBin "gacp" ''
                exec "$HOME/git/tools/a-sync/sync.sh" git remote "$@"
              '')

              # 6. GCL (Git Clone shortcut)
              (writeShellScriptBin "gcl" ''
                if [ -z "$1" ]; then
                  printf "\033[0;31mError: Repository URL required\033[0m\n"
                  printf "Usage: gcl <url> [folder]\n"
                  printf "Examples:\n"
                  printf "  gcl git@github.com:user/repo.git\n"
                  printf "  gcl https://github.com/user/repo.git\n"
                  printf "  gcl https://github.com/user/repo.git myrepo\n"
                  exit 1
                fi
                printf "\033[0;36m→ Cloning $1...\033[0m\n"
                if [ -n "$2" ]; then
                  git clone "$1" "$2" || exit 1
                else
                  git clone "$1" || exit 1
                fi
                printf "\033[0;32m✓ Done\033[0m\n"
              '')

              # 7. CONNECT (Unified hub: HM, mesh, git, drives, sync, servers, security)
              # Source: ~/git/tools/a-connect/connect.sh
              (writeShellScriptBin "connect" ''
                exec "$HOME/git/tools/a-connect/connect.sh" "$@"
              '')

              # 7b. SYNC (Rclone sync manager)
              # Source: ~/git/tools/a-sync/sync.sh
              (writeShellScriptBin "sync" ''
                exec "$HOME/git/tools/a-sync/sync.sh" "$@"
              '')

              # 8. NIX-DRIFT (Version drift detection for nix flakes)
              # Source: ./nix-version-drift.sh
              (writeShellScriptBin "nix-drift" ''
                exec ${pkgs.bash}/bin/bash ${./nix-version-drift.sh} "$@"
              '')

              # 9. CLAUDE — native binary nix derivation. Permanent path,
              # no npm install at activation (which OOM-killed half the time).
              # Pulls the published native arm64-musl binary from npm registry
              # as a content-addressed source.
              (pkgs.callPackage ./pkgs/claude-code {})
            ];

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { pkgs, lib, ... }: {
              _module.args.nodejs = pkgsNew.nodejs_22;
              imports = [
                ./modules/common.nix
                ./modules/packages.nix
                ./modules/curl-wget-wrapper.nix
                ./modules/node-npm-deps.nix
                ./modules/node-bins.nix
                ./modules/web-server-md-eruda.nix
                ./modules/sshd.nix
                ./modules/programs/shells/fish-greeting.nix
                ./modules/wireguard.nix
                ./modules/wg-keepalive.nix
              ];
              home.stateVersion = "24.05";

              # This runs BEFORE packages are linked
              home.activation.createUsrLib = lib.hm.dag.entryBefore ["writeBoundary"] ''
                $DRY_RUN_CMD mkdir -p /data/data/com.termux.nix/files/usr/lib
                $DRY_RUN_CMD chmod 755 /data/data/com.termux.nix/files/usr/lib
              '';

              # Create Unison target folder on Android storage
              home.activation.createUnisonTarget = lib.hm.dag.entryBefore ["writeBoundary"] ''
                $DRY_RUN_CMD mkdir -p "/storage/emulated/0/Mounts/Termux-Home"
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

              # Claude Code master context + MCP server config
              # CLAUDE.md is generated dynamically from template + cloud-data at activation time
              home.file.".claude/CLAUDE.md.tpl".source = ../src/modules/dotfiles/claude/CLAUDE.md.tpl;
              home.file.".claude/gen-claude-md.sh" = {
                source = ../src/modules/dotfiles/claude/gen-claude-md.sh;
                executable = true;
              };
              home.file.".claude/mcp.json.tpl".source = ../src/modules/dotfiles/claude/mcp.json.tpl;
              home.file.".claude/secrets.yaml".source = ../src/modules/dotfiles/claude/secrets.yaml;
              home.file.".claude/statusline-command.sh" = {
                source = ../src/modules/dotfiles/claude/statusline-command.sh;
                executable = true;
              };
              home.file.".claude/hooks/claude-memory.sh" = {
                source = ../src/modules/dotfiles/claude/claude-memory.sh;
                executable = true;
              };
              home.file.".claude/hooks/declarative-guard.sh" = {
                source = ../src/modules/dotfiles/claude/declarative-guard.sh;
                executable = true;
              };
              home.file.".claude/hooks/pretool-guard.sh" = {
                source = ../src/modules/dotfiles/claude/pretool-guard.sh;
                executable = true;
              };
              home.file.".claude/settings.json".source = ../src/modules/dotfiles/claude/settings.json;
              home.file.".claude/skills/frontend-design.md".source = ../src/modules/dotfiles/claude/skills/frontend-design.md;
              home.file.".rgignore".source = ../src/modules/dotfiles/claude/rgignore;

              # Gemini CLI configuration + MCP server config
              home.file.".gemini/settings.json.tpl".source = ../src/modules/dotfiles/gemini/settings.json.tpl;

              # MCP secrets: decrypt secrets.yaml → awk subst ''${VAR} → ~/.mcp.json
              # Mimics Docker env_file + init.sh pattern using awk index() (literal, no regex)
              home.activation.mcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
                SOPS="$HOME/.nix-profile/bin/sops"
                TPL="$HOME/.claude/mcp.json.tpl"
                SECRETS_YAML="$HOME/.claude/secrets.yaml"
                OUT="$HOME/.mcp.json"
                YQ="${pkgs.yq-go}/bin/yq"
                AWK="${pkgs.gawk}/bin/awk"

                if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
                  echo "[mcp-secrets] WARNING: sops/secrets/template not found, copying template as-is"
                  [ -f "$TPL" ] && cp "$TPL" "$OUT"
                  exit 0
                fi

                # Decrypt secrets.yaml (same as cloud/ _engine.sh pattern)
                DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
                if [ -z "$DECRYPTED" ]; then
                  echo "[mcp-secrets] WARNING: failed to decrypt secrets.yaml"
                  cp "$TPL" "$OUT"
                  exit 0
                fi

                # Copy template to output
                cp "$TPL" "$OUT"

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

              # Generate CLAUDE.md from template + cloud-data (dynamic VM/service tables)
              home.activation.genClaudeMd = lib.hm.dag.entryAfter ["linkGeneration"] ''
                GEN="$HOME/.claude/gen-claude-md.sh"
                if [ -x "$GEN" ]; then
                  NODE_BIN="${pkgs.nodejs_22}/bin/node" \
                    $DRY_RUN_CMD "$GEN" \
                      "$HOME/.claude/CLAUDE.md.tpl" \
                      "$HOME/.claude/CLAUDE.md" \
                      "$HOME/git/cloud/cloud-data" \
                    || echo "[gen-claude-md] WARNING: generation failed, template used as fallback"
                else
                  echo "[gen-claude-md] WARNING: gen-claude-md.sh not found"
                fi
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

                  # NOTE: sshd auto-start lives in modules/sshd.nix (`termux-sshd start`).
                  # The previous block here referenced ~/.ssh/sshd_config which is never
                  # created — it failed silently and hid real startup errors. Removed.

                  # Auto-start http-dev (web-server-md-eruda)
                  set -g __httpd_port 8000
                  if command -q http-dev
                    http-dev start >/dev/null 2>&1
                    set -g __httpd_pid (cat ~/.cache/web-server-md-eruda.pid 2>/dev/null)
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


                  # Greeting is in modules/programs/shells/fish-greeting.nix
                '';
              };
            };
          })
        ];
      };
    };
}
