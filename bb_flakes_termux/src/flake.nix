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
        cc = "cclaude";
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
              PATH = "$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH";
              # Global memory allocator fix for Android - propagates to ALL child processes
              LD_PRELOAD = "${pkgs.mimalloc}/lib/libmimalloc.so";
              MIMALLOC_PAGE_RESET = "0";
              MIMALLOC_LARGE_OS_PAGES = "0";
              MALLOC_ARENA_MAX = "2";
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
              sops
              age
              yq-go

              # Cloud CLIs
              gh
              flarectl
              cloudflared
              google-cloud-sdk
              oci-cli

              # Infrastructure as Code
              terraform

              # VPN & networking
              wireguard-tools
              inetutils
              termux-am

              # Node 22 (from nixos-24.11 for Vite 7 compat: requires >=22.12)
              pkgsNew.nodejs_22

              # 1. CLAUDE (Standard with jemalloc fix)
              (writeShellScriptBin "claude" ''
                export HOME="/data/data/com.termux.nix/files/home"
                export LD_PRELOAD="$(nix-build '<nixpkgs>' -A jemalloc --no-out-link)/lib/libjemalloc.so"
                export UV_USE_IO_URING=0
                export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=1024"
                export npm_config_cache="$HOME/.npm"
                exec ${pkgsNew.nodejs_22}/bin/npx -y @anthropic-ai/claude-code "$@"
              '')

              # 2. CCLAUDE (With tmp dir workaround)
              (writeShellScriptBin "cclaude" ''
                export HOME="/data/data/com.termux.nix/files/home"
                export LD_PRELOAD="$(nix-build '<nixpkgs>' -A jemalloc --no-out-link)/lib/libjemalloc.so"
                export MALLOC_ARENA_MAX=2
                export UV_USE_IO_URING=0
                export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=2048"
                export CLAUDE_TMP="$HOME/tmp/claude"
                mkdir -p "$CLAUDE_TMP"
                export TMPDIR="$CLAUDE_TMP"
                export npm_config_cache="$HOME/.npm"
                exec ${pkgsNew.nodejs_22}/bin/npx -y @anthropic-ai/claude-code "$@"
              '')

              # 3. SYNC — delegates to ~/git/front/sync.sh (Rclone + Eruda HTTP)
              (writeShellScriptBin "sync" ''
                exec "$HOME/git/front/sync.sh" "$@"
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

              # 5. GACP (Git Add, Commit, Push)
              (writeShellScriptBin "gacp" ''
                if [ -z "$1" ]; then
                  printf "\033[0;31mError: Commit message required\033[0m\n"
                  printf "Usage: gacp \"commit message\"\n"
                  exit 1
                fi
                printf "\033[0;36m→ Adding all changes...\033[0m\n"
                git add . || exit 1
                printf "\033[0;36m→ Committing: $1\033[0m\n"
                git commit -m "$1" || exit 1
                printf "\033[0;36m→ Pushing...\033[0m\n"
                git push || exit 1
                printf "\033[0;32m✓ Done\033[0m\n"
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
              # Auto-discovers config at ~/.config/wireguard/wg0.conf
              # (symlinked by vault/build.sh setup wireguard)
              (writeShellScriptBin "mesh" ''
                WG_DIR="$HOME/.config/wireguard"
                WG_CONF="$WG_DIR/wg0.conf"

                C_RESET="\033[0m"
                C_CYAN="\033[0;36m"
                C_GREEN="\033[0;32m"
                C_YELLOW="\033[0;33m"
                C_RED="\033[0;31m"
                C_DIM="\033[2m"

                if [ ! -f "$WG_CONF" ]; then
                  printf "''${C_RED}WireGuard config not found: %s''${C_RESET}\n" "$WG_CONF" >&2
                  printf "''${C_DIM}Run: ~/git/vault/build.sh setup wireguard''${C_RESET}\n" >&2
                  exit 1
                fi

                WG_TUNNEL="wg0"

                case "''${1:-}" in
                  up)
                    printf "''${C_CYAN}Starting WireGuard tunnel...''${C_RESET}\n"
                    ${termux-am}/bin/am broadcast -a com.wireguard.android.action.SET_TUNNEL_UP -n com.wireguard.android/.model.TunnelManager\$IntentReceiver -e tunnel "$WG_TUNNEL" 2>&1 | grep -v "^$"
                    sleep 2
                    if ${pkgs.inetutils}/bin/ping -c 1 -W 2 10.0.0.1 >/dev/null 2>&1; then
                      printf "''${C_GREEN}Mesh is UP''${C_RESET}\n"
                    else
                      printf "''${C_YELLOW}Broadcast sent — check WireGuard app if peers don't respond''${C_RESET}\n"
                    fi
                    ;;
                  down)
                    printf "''${C_YELLOW}Stopping WireGuard tunnel...''${C_RESET}\n"
                    ${termux-am}/bin/am broadcast -a com.wireguard.android.action.SET_TUNNEL_DOWN -n com.wireguard.android/.model.TunnelManager\$IntentReceiver -e tunnel "$WG_TUNNEL" 2>&1 | grep -v "^$"
                    printf "''${C_GREEN}Mesh is DOWN''${C_RESET}\n"
                    ;;
                  status)
                    printf "''${C_CYAN}=== WireGuard Mesh Status ===''${C_RESET}\n"
                    printf "\n"
                    # TCP connect to port 22 (ping needs root for ICMP)
                    for peer in "10.0.0.1 gcp-proxy" "10.0.0.2 oci-flex" "10.0.0.3 oci-mail" "10.0.0.4 oci-analytics"; do
                      IP=$(echo "$peer" | cut -d' ' -f1)
                      NAME=$(echo "$peer" | cut -d' ' -f2)
                      printf "  %-16s %-8s " "$NAME" "$IP"
                      if timeout 3 bash -c "echo >/dev/tcp/$IP/22" 2>/dev/null; then
                        printf "''${C_GREEN}UP''${C_RESET}\n"
                      else
                        printf "''${C_RED}DOWN''${C_RESET}\n"
                      fi
                    done
                    printf "\n"
                    printf "''${C_DIM}Local: 10.0.0.5''${C_RESET}\n"
                    ;;
                  config)
                    # Output config for WireGuard Android app import
                    cat "$WG_CONF"
                    ;;
                  path)
                    # Output config path (for WireGuard app file import)
                    printf "%s" "$WG_CONF"
                    ;;
                  peers)
                    printf "''${C_CYAN}=== Mesh Peers ===''${C_RESET}\n"
                    printf "  ''${C_GREEN}%-16s''${C_RESET} %-10s %-22s %s\n" "NAME" "WG IP" "PUBLIC IP" "ROLE"
                    printf "  %-16s %-10s %-22s %s\n" "gcp-proxy"      "10.0.0.1" "35.226.147.64"   "hub (24/7)"
                    printf "  %-16s %-10s %-22s %s\n" "oci-flex"       "10.0.0.2" "144.24.196.72"   "apps (wake-on-demand)"
                    printf "  %-16s %-10s %-22s %s\n" "oci-mail"       "10.0.0.3" "130.110.251.193" "mail (24/7)"
                    printf "  %-16s %-10s %-22s %s\n" "oci-analytics"  "10.0.0.4" "129.151.228.66"  "analytics (24/7)"
                    printf "  ''${C_YELLOW}%-16s''${C_RESET} %-10s %-22s %s\n" "local (you)" "10.0.0.5" "N/A" "client"
                    ;;
                  *)
                    printf "''${C_CYAN}=== WireGuard Mesh VPN ===''${C_RESET}\n"
                    printf "\n"
                    printf "''${C_YELLOW}Commands:''${C_RESET}\n"
                    printf "  ''${C_GREEN}mesh up''${C_RESET}       Start VPN tunnel\n"
                    printf "  ''${C_GREEN}mesh down''${C_RESET}     Stop VPN tunnel\n"
                    printf "  ''${C_GREEN}mesh status''${C_RESET}   Ping all peers\n"
                    printf "  ''${C_GREEN}mesh config''${C_RESET}   Show wg0.conf (for app import)\n"
                    printf "  ''${C_GREEN}mesh path''${C_RESET}     Show config file path\n"
                    printf "  ''${C_GREEN}mesh peers''${C_RESET}    Show peer topology\n"
                    printf "\n"
                    printf "''${C_YELLOW}First-time setup:''${C_RESET}\n"
                    printf "  1. Install WireGuard app + allow external control\n"
                    printf "  2. Import config: ''${C_DIM}mesh config''${C_RESET}\n"
                    printf "  3. Then use: ''${C_DIM}mesh up / mesh down''${C_RESET}\n"
                    ;;
                esac
              '')

              # 8. BEARER (Authelia bearer token for CLI access)
              # Auto-discovers token at ~/.config/authelia/tokens.json
              # (symlinked by vault/build.sh setup authelia)
              (writeShellScriptBin "bearer" ''
                TOKEN_FILE="$HOME/.config/authelia/tokens.json"
                if [ ! -f "$TOKEN_FILE" ]; then
                  printf "\033[0;31mToken file not found: %s\033[0m\n" "$TOKEN_FILE" >&2
                  exit 1
                fi
                TOKEN=$(${pkgs.jq}/bin/jq -r .access_token "$TOKEN_FILE")
                if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
                  printf "\033[0;31mNo access_token in %s\033[0m\n" "$TOKEN_FILE" >&2
                  exit 1
                fi
                case "''${1:-}" in
                  -H|--header)
                    printf "Authorization: Bearer %s" "$TOKEN"
                    ;;
                  -e|--export)
                    printf "export AUTHELIA_BEARER_TOKEN='%s'" "$TOKEN"
                    ;;
                  -c|--curl)
                    shift
                    exec ${pkgs.curl}/bin/curl -s -H "Authorization: Bearer $TOKEN" "$@"
                    ;;
                  -i|--info)
                    EXPIRES=$(${pkgs.jq}/bin/jq -r .expires_at "$TOKEN_FILE")
                    OBTAINED=$(${pkgs.jq}/bin/jq -r .obtained_at "$TOKEN_FILE")
                    printf "\033[0;36mAuthelia Bearer Token\033[0m\n"
                    printf "  Obtained: \033[0;33m%s\033[0m\n" "$OBTAINED"
                    printf "  Expires:  \033[0;33m%s\033[0m\n" "$EXPIRES"
                    printf "  Token:    \033[0;32m%s...\033[0m\n" "$(echo "$TOKEN" | cut -c1-40)"
                    ;;
                  *)
                    printf "%s" "$TOKEN"
                    ;;
                esac
              '')
            ];

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { pkgs, lib, ... }: {
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

              # Termux font — JetBrainsMono Nerd Font
              home.file.".termux/font.ttf".source =
                "${pkgs.nerdfonts.override { fonts = [ "JetBrainsMono" ]; }}/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf";

              # Claude Code master context + MCP server config
              home.file.".claude/CLAUDE.md".source = ../src/modules/dotfiles/claude/CLAUDE.md;
              home.file.".mcp.json".source = ../src/modules/dotfiles/claude/mcp.json;

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

                  # Override gcc cc with cclaude (function beats PATH)
                  function cc; cclaude $argv; end

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

                  # Show custom welcome
                  set_color cyan
                  echo "=================================="
                  echo "   Nix-on-Droid Terminal"
                  echo "=================================="
                  set_color normal
                  echo ""
                  set_color yellow
                  echo "Commands:"
                  set_color normal
                  set_color green; echo -n "  c       "; set_color normal; echo "Launch Claude Code"
                  set_color green; echo -n "  cc      "; set_color normal; echo "Launch Claude Code (alt)"
                  set_color green; echo -n "  code    "; set_color normal; echo "VS Code Server (local/lan/stop)"
                  set_color cyan
                  echo ""
                  echo "Git:"
                  set_color normal
                  set_color yellow; echo -n "  gacp    "; set_color normal; echo "git add . && commit && push"
                  set_color yellow; echo -n "  gcl     "; set_color normal; echo "git clone <url>"
                  set_color cyan
                  echo ""
                  echo "Cloud:"
                  set_color normal
                  set_color red; echo -n "  bearer  "; set_color normal; echo "Authelia token (-c curl, -i info, -H header)"
                  set_color red; echo -n "  mesh    "; set_color normal; echo "WireGuard VPN (status, config, peers)"
                  set_color cyan
                  echo ""
                  echo "System:"
                  set_color normal
                  set_color magenta; echo -n "  up      "; set_color normal; echo "Rebuild Nix config"
                  set_color magenta; echo -n "  conf    "; set_color normal; echo "Edit flake.nix"
                  set_color magenta; echo -n "  sync    "; set_color normal; echo "File sync & serve (WebDAV SFTP HTTP+Eruda)"
                  set_color magenta; echo -n "  server  "; set_color normal; echo "Dev server control (dev/stop/status)"
                  set_color cyan
                  echo ""
                  echo "Search (fzf):"
                  set_color normal
                  set_color blue; echo -n "  Ctrl+T  "; set_color normal; echo "Find file"
                  set_color blue; echo -n "  Ctrl+R  "; set_color normal; echo "Search history"
                  set_color blue; echo -n "  Alt+C   "; set_color normal; echo "Cd to folder"
                  set_color cyan
                  echo ""
                  echo "Navigation:"
                  set_color normal
                  set_color blue; echo -n "  ll      "; set_color normal; echo "List files (detailed)"
                  set_color blue; echo -n "  ..      "; set_color normal; echo "Go up one directory"
                  set_color cyan
                  echo "=================================="
                  set_color normal
                '';
              };
            };
          })
        ];
      };
    };
}
