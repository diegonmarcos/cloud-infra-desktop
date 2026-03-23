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
              max-jobs = 2
              cores = 4
              auto-optimise-store = true
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

              # 7. CONNECT (Unified hub: HM, mesh, git, drives, sync, servers, security)
              # Source: ~/git/tools/a-cloud-connect/connect.sh
              (writeShellScriptBin "connect" ''
                exec "$HOME/git/tools/a-cloud-connect/connect.sh" "$@"
              '')

              # 8. NIX-DRIFT (Version drift detection for nix flakes)
              # Source: ./nix-version-drift.sh
              (writeShellScriptBin "nix-drift" ''
                exec ${pkgs.bash}/bin/bash ${./nix-version-drift.sh} "$@"
              '')
            ];

            # --- HOME MANAGER CONFIG ---
            home-manager.config = { pkgs, lib, ... }: {
              _module.args.nodejs = pkgsNew.nodejs_22;
              imports = [
                ./modules/packages.nix
                ./modules/guardrails.nix
                ./modules/curl-wget-wrapper.nix
                ./modules/node-deps.nix
                ./modules/node-bins.nix
                ./modules/web-server-md-eruda.nix
                ./modules/programs/shells/fish-greeting.nix
                ./modules/wireguard.nix
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

                  # Auto-start http-dev (web-server-md-eruda)
                  set -g __httpd_port 8000
                  set -g __httpd_pid (http-dev start 2>/dev/null)

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
