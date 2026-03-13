{
  description = "Nix-on-Droid Termux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-new.url = "github:NixOS/nixpkgs/nixos-24.11";

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-new, nix-on-droid, home-manager }:
    let
      pkgsNew = import nixpkgs-new { system = "aarch64-linux"; };

      # Build termux-am from nix-on-droid source (provides `am` for Android intents)
      termux-am = (import nixpkgs { system = "aarch64-linux"; }).callPackage
        "${nix-on-droid}/pkgs/android-integration/termux-am.nix" {};

      # Shared aliases for all shells
      sharedAliases = {
        ll = "ls -alh";
        ".." = "cd ..";
        conf = "nano ~/nix-home-manager/flake.nix";
        up = "~/nix-home-manager/build.sh switch";
        c = "claude";
        cc = "claude-malloc";
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
            '';

            time.timeZone = "Europe/Athens";

            # Global PATH and SHELL for Bash/Zsh/Fish
            environment.sessionVariables = {
              SHELL = "${pkgs.bash}/bin/bash";
              PATH = "$HOME/.node_modules/node_modules/.bin:$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH";
              NODE_PATH = "$HOME/.node_modules/node_modules";
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
              vim
              coreutils
              openssh
              strace
              unison
              rclone
              procps
              gawk
              findutils
              fzf
              iproute2  # Provides 'ip' command for network interface management

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

              # VPN & networking
              # NOTE: wireguard-tools (wg CLI) requires root — useless on Android.
              # The WireGuard Android app manages the tunnel via VPN API instead.
              # We provide a wrapper that warns and redirects to `mesh`.
              (writeShellScriptBin "wg" ''
                echo ""
                echo "  THIS IS A ROOTLESS ANDROID!"
                echo "  You should NEVER try to check WireGuard connection using wg!"
                echo ""
                echo "  Use the 'mesh' command instead:"
                echo "    mesh status   — check VPN tunnel status"
                echo "    mesh up       — bring tunnel up (via Android WG app)"
                echo "    mesh down     — bring tunnel down"
                echo "    mesh peers    — show configured peers"
                echo ""
              '')
              inetutils
              termux-am

              # Node 22 (from nixos-24.11 for Vite 7 compat: requires >=22.12)
              pkgsNew.nodejs_22

              # 1. CLAUDE (native install preferred, npx fallback for legacy)
              (writeShellScriptBin "claude" ''
                export HOME="/data/data/com.termux.nix/files/home"
                export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/data/data/com.termux.nix/files/usr/bin:$PATH"
                export UV_USE_IO_URING=0
                export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=1024"
                export npm_config_cache="$HOME/.npm"
                GLOBAL_BIN="/data/data/com.termux.nix/files/usr/bin/claude"
                NPM_BIN="$(${pkgsNew.nodejs_22}/bin/npm root -g 2>/dev/null)/../bin/claude"
                if [ -x "$GLOBAL_BIN" ]; then exec "$GLOBAL_BIN" "$@"
                elif [ -x "$NPM_BIN" ]; then exec "$NPM_BIN" "$@"
                else exec ${pkgsNew.nodejs_22}/bin/npx -y @anthropic-ai/claude-code "$@"
                fi
              '')

              # 2. CLAUDE-MALLOC (With tmp dir workaround + higher memory limit)
              (writeShellScriptBin "claude-malloc" ''
                export HOME="/data/data/com.termux.nix/files/home"
                export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/data/data/com.termux.nix/files/usr/bin:$PATH"
                export MALLOC_ARENA_MAX=2
                export UV_USE_IO_URING=0
                export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=2048"
                export CLAUDE_TMP="$HOME/tmp/claude"
                mkdir -p "$CLAUDE_TMP"
                export TMPDIR="$CLAUDE_TMP"
                export npm_config_cache="$HOME/.npm"
                GLOBAL_BIN="/data/data/com.termux.nix/files/usr/bin/claude"
                NPM_BIN="$(${pkgsNew.nodejs_22}/bin/npm root -g 2>/dev/null)/../bin/claude"
                if [ -x "$GLOBAL_BIN" ]; then exec "$GLOBAL_BIN" "$@"
                elif [ -x "$NPM_BIN" ]; then exec "$NPM_BIN" "$@"
                else exec ${pkgsNew.nodejs_22}/bin/npx -y @anthropic-ai/claude-code "$@"
                fi
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

              # 7. MESH (WireGuard VPN mesh management)
              # Source: ~/git/tools/a-Mesh/mesh.sh + mesh.json
              (writeShellScriptBin "mesh" ''
                exec "$HOME/git/tools/a-Mesh/mesh.sh" "$@"
              '')

              # 7b. CONNECT (Unified dashboard: git, mounts, sync, servers)
              # Source: ~/git/tools/a-cloud-connect/connect.sh
              (writeShellScriptBin "connect" ''
                exec "$HOME/git/tools/a-cloud-connect/connect.sh" "$@"
              '')
            ];

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { pkgs, lib, ... }: {
              _module.args.nodejs = pkgsNew.nodejs_22;
              imports = [
                ./modules/packages.nix
                ./modules/guardrails.nix
                ./modules/curl-wrapper.nix
                ./modules/node-deps.nix
                ./modules/cloud.nix
                ./modules/front.nix
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

              # Global tsx (TypeScript runner)
              home.activation.globalTsx = lib.hm.dag.entryAfter ["linkGeneration"] ''
                PATH="${pkgsNew.nodejs_22}/bin:$PATH"
                if ! command -v tsx >/dev/null 2>&1; then
                  $DRY_RUN_CMD ${pkgsNew.nodejs_22}/bin/npm install -g tsx --no-audit --no-fund || true
                fi
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
              home.file.".claude/CLAUDE.md".source = ../src/modules/dotfiles/claude/CLAUDE.md;
              home.file.".mcp.json".source = ../src/modules/dotfiles/claude/mcp.json;
              home.file.".claude/statusline-command.sh" = {
                source = ../src/modules/dotfiles/claude/statusline-command.sh;
                executable = true;
              };
              home.file.".claude/hooks/claude-memory.sh" = {
                source = ../src/modules/dotfiles/claude/claude-memory.sh;
                executable = true;
              };
              home.file.".claude/settings.json".source = ../src/modules/dotfiles/claude/settings.json;
              home.file.".claude/skills/frontend-design.md".source = ../src/modules/dotfiles/claude/skills/frontend-design.md;
              home.file.".rgignore".source = ../src/modules/dotfiles/claude/rgignore;

              # Lightweight Node.js file server with Eruda DevTools + Markdown rendering
              home.file.".local/bin/web-server-md-eruda.mjs".source = ../src/modules/dotfiles/web-server-md-eruda.mjs;
              home.file.".local/lib/httpd/marked.min.js".source = ../src/modules/dotfiles/httpd-lib/marked.min.js;
              home.file.".local/lib/httpd/github-markdown-dark.css".source = ../src/modules/dotfiles/httpd-lib/github-markdown-dark.css;

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
                  # Disable default greeting
                  set -g fish_greeting ""

                  # Override gcc cc with claude-malloc (function beats PATH)
                  function cc; claude-malloc $argv; end

                  # Auto-start node file server with Eruda DevTools + Markdown on port 8000
                  set -g __httpd_port 8000
                  set -g __httpd_dir "$HOME"
                  set -g __httpd_pid_file "$HOME/.cache/web-server-md-eruda.pid"
                  set -l httpd_running 0
                  if test -f "$__httpd_pid_file"
                    set -l pid (cat "$__httpd_pid_file" 2>/dev/null)
                    if test -n "$pid"; and kill -0 $pid 2>/dev/null
                      set httpd_running 1
                    end
                  end
                  if test $httpd_running -eq 0
                    mkdir -p (dirname "$__httpd_pid_file")
                    node "$HOME/.local/bin/web-server-md-eruda.mjs" "$__httpd_port" "$__httpd_dir" >/dev/null 2>&1 &
                    echo $last_pid > "$__httpd_pid_file"
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


                  # ════════════════════════════════════════════════════════
                  # WELCOME SCREEN
                  # ════════════════════════════════════════════════════════

                  # ── Gather all data (local only, no network calls) ──
                  set -l _cpu (uname -m 2>/dev/null; or echo "n/a")
                  set -l _cores (nproc 2>/dev/null; or echo "?")
                  set -l _mt (free -h 2>/dev/null | awk '/Mem:/{print $2}'); test -z "$_mt"; and set _mt "n/a"
                  set -l _mu (free -h 2>/dev/null | awk '/Mem:/{print $3}'); test -z "$_mu"; and set _mu "n/a"
                  set -l _kern (uname -r 2>/dev/null | string split "-" | head -1; or echo "n/a")
                  set -l _host (hostname 2>/dev/null; or echo "termux")
                  set -l _up (uptime -p 2>/dev/null | string replace "up " ""); test -z "$_up"; and set _up "n/a"
                  set -l _nix ("$HOME/.nix-profile/bin/nix" --version 2>/dev/null | string replace -r ".*\\) " ""); test -z "$_nix"; and set _nix "n/a"
                  set -l _hmg "n/a"
                  if test -L "$HOME/.local/state/nix/profiles/home-manager"
                    set _hmg (readlink "$HOME/.local/state/nix/profiles/home-manager" 2>/dev/null | string replace -r ".*-(\\d+)-link" '$1')
                    test -z "$_hmg"; and set _hmg "n/a"
                  end
                  set -l _wg "down"; set -l _wgip "n/a"
                  set -l _wo (ip -4 addr show wg0 2>/dev/null | string match -r "inet (\\S+)/" | tail -1)
                  if test -n "$_wo"; set _wg "up"; set _wgip "$_wo"; end
                  set -l _lan (ip -4 route get 1 2>/dev/null | string match -r "src (\\S+)" | tail -1)
                  test -z "$_lan"; and set _lan "n/a"
                  set -l _dhome (df -h ~ 2>/dev/null | awk 'NR==2{print $3"/"$2}'); test -z "$_dhome"; and set _dhome "n/a"
                  set -l _dpct (df -h ~ 2>/dev/null | awk 'NR==2{print $5}'); test -z "$_dpct"; and set _dpct "n/a"
                  set -l _dnix (df -h /nix 2>/dev/null | awk 'NR==2{print $3"/"$2}'); test -z "$_dnix"; and set _dnix "n/a"
                  set -l _gbr (git -C "$HOME" branch --show-current 2>/dev/null; or echo "n/a")
                  set -l _grepo (bash -c 'ls -1d ~/git/*/.git 2>/dev/null | wc -l | tr -d " "'); test -z "$_grepo"; and set _grepo "0"
                  set -l _gdirty (git -C "$HOME" status --porcelain 2>/dev/null | wc -l | string trim); test -z "$_gdirty"; and set _gdirty "0"

                  # ══════════════════ H1: Title Banner ══════════════════
                  set_color --bold cyan
                  echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
                  echo "   Nix-on-Droid Terminal"
                  echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
                  set_color normal; echo ""

                  # ══════════════════ H2: System ══════════════════
                  set_color --bold yellow; echo "── System ─────────────────────────────────────────────────────────────────────────────────────"
                  set_color normal

                  # Row 1: Hardware | OS | Nix
                  set_color yellow
                  printf "┌─ Hardware ────────────────────┐ ┌─ OS ──────────────────────────┐ ┌─ Nix ─────────────────────────┐\n"
                  printf "│"; set_color normal; printf " %-30s" "Arch: $_cpu ($_cores cores)"; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Type: Android/Termux"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "Nix: $_nix"; set_color yellow; printf "│\n"
                  printf "│"; set_color normal; printf " %-30s" "RAM: $_mu / $_mt"; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Host: $_host"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "HM Generation: $_hmg"; set_color yellow; printf "│\n"
                  printf "│"; set_color normal; printf " %-30s" "Kernel: $_kern"; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Shell: fish"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "HM: git/unix/bb_flakes_termux"; set_color yellow; printf "│\n"
                  printf "│"; set_color normal; printf " %-30s" ""; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Uptime: $_up"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "OS Flake: n/a (Termux)"; set_color yellow; printf "│\n"
                  printf "└────────────────────────────────┘ └────────────────────────────────┘ └───────────────────────────────┘\n"
                  set_color normal

                  # ══════════════════ H2: Network & Data ══════════════════
                  set_color --bold cyan; echo "── Network & Data ─────────────────────────────────────────────────────────────────────────────"
                  set_color normal

                  # Row 2: Network | Storage | Git
                  set_color cyan
                  printf "┌─ Network ─────────────────────┐ ┌─ Storage ─────────────────────┐ ┌─ Git ─────────────────────────┐\n"
                  printf "│"; set_color normal; printf " WG: "
                  if test "$_wg" = "up"; set_color green; printf "● up "; else; set_color red; printf "○ dn "; end
                  set_color normal; printf "%-24s" "IP: $_wgip"; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" "Home: $_dhome ($_dpct)"; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" "Branch: $_gbr"; set_color cyan; printf "│\n"
                  printf "│"; set_color normal; printf " %-30s" "LAN: $_lan"; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" "Nix:  $_dnix"; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" "Repos: $_grepo  Dirty: $_gdirty"; set_color cyan; printf "│\n"
                  printf "│"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" ""; set_color cyan; printf "│\n"
                  printf "│"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" ""; set_color cyan; printf "│\n"
                  printf "└────────────────────────────────┘ └────────────────────────────────┘ └───────────────────────────────┘\n"
                  set_color normal; echo ""

                  # ══════════════════ H2: Configuration ══════════════════
                  set_color --bold magenta; echo "── Configuration ──────────────────────────────────────────────────────────────────────────────"
                  set_color normal
                  # H3: Wrappers - Guardrails
                  set_color cyan; echo "  Wrappers - Guardrails:"
                  set_color normal
                  set_color red; echo -n "    BLOCKED "; set_color normal; echo "rm -rf /, mkfs, dd (always denied)"
                  set_color yellow; echo -n "    CONFIRM "; set_color normal; echo "npm npx docker nix pip apt pkg (ask before run)"
                  set_color blue; echo -n "    WARNING "; set_color normal; echo "bun cargo go (warn on write ops)"
                  # H3: Wrappers - Custom
                  set_color cyan; echo "  Wrappers - Custom:"
                  set_color normal
                  set_color green; echo -n "    curl    "; set_color normal; echo "Auto-inject Authelia bearer token for *.diegonmarcos.com"
                  set_color green; echo -n "    wget    "; set_color normal; echo "Auto-inject Authelia bearer token for *.diegonmarcos.com"
                  # H3: Env Vars
                  set_color cyan; echo "  Env Vars:"
                  set_color normal
                  set_color magenta; echo -n "    LD_PRELOAD       "; set_color normal; echo "mimalloc (memory allocator fix)"
                  set_color magenta; echo -n "    TF_PLUGIN_CACHE  "; set_color normal; echo "~/.terraform.d/plugin-cache"
                  if test -n "$CLOUDFLARE_API_TOKEN"
                    set_color green; echo -n "    CF_API_TOKEN     "; set_color normal; echo "● set"
                  else
                    set_color red; echo -n "    CF_API_TOKEN     "; set_color normal; echo "○ not set"
                  end
                  if test -f "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/monitoring-read.json"
                    set_color green; echo -n "    AUTHELIA_TOKEN   "; set_color normal; echo "● available"
                  else
                    set_color red; echo -n "    AUTHELIA_TOKEN   "; set_color normal; echo "○ not found"
                  end
                  echo ""

                  # ══════════════════ H2: Commands ══════════════════
                  set_color --bold green; echo "── Commands ───────────────────────────────────────────────────────────────────────────────────"
                  set_color normal
                  # H3: Tools
                  set_color cyan; echo "  Tools:"
                  set_color normal
                  set_color green; echo -n "    c       "; set_color normal; echo "Launch Claude Code"
                  set_color green; echo -n "    cc      "; set_color normal; echo "Launch Claude Code (alt)"
                  set_color green; echo -n "    code    "; set_color normal; echo "VS Code Server (local/lan/stop)"
                  # H3: Git
                  set_color cyan; echo "  Git:"
                  set_color normal
                  set_color yellow; echo -n "    gacp    "; set_color normal; echo "git add . && commit && push"
                  set_color yellow; echo -n "    gcl     "; set_color normal; echo "git clone <url>"
                  # H3: Cloud
                  set_color cyan; echo "  Cloud:"
                  set_color normal
                  set_color red; echo -n "    curl    "; set_color normal; echo "Auto-injects Authelia token for *.diegonmarcos.com"
                  set_color red; echo -n "    mesh    "; set_color normal; echo "WireGuard VPN (status, config, peers)"
                  # H3: System
                  set_color cyan; echo "  System:"
                  set_color normal
                  set_color magenta; echo -n "    up      "; set_color normal; echo "Rebuild Nix config"
                  set_color magenta; echo -n "    conf    "; set_color normal; echo "Edit flake.nix"
                  set_color magenta; echo -n "    sync    "; set_color normal; echo "File sync & serve (WebDAV SFTP HTTP+Eruda)"
                  set_color magenta; echo -n "    connect "; set_color normal; echo "Unified dashboard (git/mounts/sync/servers)"
                  set_color magenta; echo -n "    server  "; set_color normal; echo "Dev server control (dev/stop/status)"
                  if test -f "$__httpd_pid_file"; and kill -0 (cat "$__httpd_pid_file" 2>/dev/null) 2>/dev/null
                    set -l __httpd_pid (cat "$__httpd_pid_file")
                    set_color green; echo -n "    httpd   "; set_color normal; echo -n "● Web+MD+Eruda "; set_color cyan; echo -n "http://127.0.0.1:$__httpd_port"; set_color normal; echo " (PID: $__httpd_pid)"
                  else
                    set_color red; echo -n "    httpd   "; set_color normal; echo "○ Not running"
                  end
                  # H3: Search
                  set_color cyan; echo "  Search (fzf):"
                  set_color normal
                  set_color blue; echo -n "    Ctrl+T  "; set_color normal; echo "Find file"
                  set_color blue; echo -n "    Ctrl+R  "; set_color normal; echo "Search history"
                  set_color blue; echo -n "    Alt+C   "; set_color normal; echo "Cd to folder"

                  set_color cyan; echo ""
                  echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
                  set_color normal
                '';
              };
            };
          })
        ];
      };
    };
}
