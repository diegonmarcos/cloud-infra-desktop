# Fish shell configuration - Comprehensive
{ config, pkgs, lib, ... }:

{
  programs.fish = {
    enable = true;

    shellAbbrs = {
      # Git abbreviations (expand on space)
      gs = "git status -sb";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gp = "git push";
      gl = "git log --oneline --graph --decorate -20";
      gd = "git diff";
      gco = "git checkout";
      gpl = "git pull";
      gcl = "git clone";

      # Docker abbreviations
      dps = "docker ps";
      dpsa = "docker ps -a";
      dcu = "docker compose up";
      dcd = "docker compose down";
    };

    shellAliases = {
      # Modern CLI
      ls = "eza --color=auto --icons";
      ll = "eza -alF --icons";
      la = "eza -A --icons";
      l = "eza -CF --icons";
      lh = "eza -lh --icons";
      lt = "eza --tree --level=2 --icons";
      cat = "bat --paging=never";
      grep = "rg";
      find = "fd";
      # docker is real docker — no alias needed

      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";

      # Safety
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";

      # Python
      py = "python3";
      python = "python3";
      pip = "pip3";
      ppy = "poetry run python3";

      # System
      df = "duf";
      du = "ncdu";
      free = "free -h";
      ports = "ss -tulanp";
      myip = "curl -s ifconfig.me";

      # Misc
      c = "clear";
      cls = "clear";
      h = "history";
      path = "echo $PATH | tr ':' '\\n'";
      reload = "source ~/.config/fish/config.fish";

      # Session (Plasma 6)
      logout = "killall -9 -u $USER; qdbus org.kde.Shutdown /Shutdown logout";
      reboot = "qdbus org.kde.Shutdown /Shutdown logoutAndReboot";
      poweroff = "qdbus org.kde.Shutdown /Shutdown logoutAndShutdown";

      # Browser dev
      chrome_no_CORS = "chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors";

      # Custom tools
      gdrive = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh";

      # AI CLIs — see interactiveShellInit for ai-cli function

      # Welcome screen
      welcome = "_show_welcome";
    };

    functions = {
      "ai-cli" = "sh $HOME/git/tools/b-scripts/ai-cli/ai-cli.sh $argv";
      "cloud-ai-cli" = "ai-cli $argv";

      fish_greeting = ''
        # Gather system info
        set -l user (whoami)
        set -l host (hostname -s)
        set -l hostname_full (hostname)
        set -l profile "$HM_PROFILE"; test -z "$profile" && set profile "unknown"
        set -l os "NixOS"
        set -l kernel (uname -r)
        set -l kernel_short (uname -r | cut -d'-' -f1)
        set -l arch (uname -m)
        set -l shell "Fish $FISH_VERSION"
        set -l de "$XDG_CURRENT_DESKTOP"
        set -l uptime_secs (command cat /proc/uptime | cut -d. -f1)
        set -l uptime_days (math -s0 "$uptime_secs / 86400")
        set -l uptime_hours (math -s0 "($uptime_secs % 86400) / 3600")
        set -l uptime_mins (math -s0 "($uptime_secs % 3600) / 60")
        set -l uptime_str "$uptime_days"d" ""$uptime_hours"h" ""$uptime_mins"m
        set -l cpu_name (command grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //' | sed 's/(R)//g' | sed 's/(TM)//g' | string sub -l 25)
        set -l cpu_cores (nproc)
        set -l cpu_freq (math -s0 (command cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)" / 1000")
        set -l mem_info (command free -h | awk '/Mem:/ {print $3"/"$2}')
        set -l mem_perc (command free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
        set -l disk_info (command df -h /nix | awk 'NR==2 {print $3"/"$2}')
        set -l disk_perc (command df /nix | awk 'NR==2 {gsub(/%/,""); print $5}')
        set -l ip_addr (curl -sf --max-time 2 ifconfig.me 2>/dev/null; or echo "offline")
        set -l ip_priv (ip -4 addr show scope global 2>/dev/null | awk '/inet / {gsub(/\/.*/, "", $2); iface=$NF; if (iface !~ /docker|br-|veth/) printf "%s(%s) ", $2, iface}' | string trim)
        set -l load_avg (command cat /proc/loadavg | awk '{print $1" "$2" "$3}')
        set -l pkgs (command ls /nix/store 2>/dev/null | wc -l | string trim)
        set -l procs (command ls /proc 2>/dev/null | grep -c '^[0-9]')
        set -l datetime (date '+%d-%m-%Y %H:%M')
        set -l gpu (lspci 2>/dev/null | grep -i vga | sed 's/.*: //' | string sub -l 25)

        # Security info
        set -l ssh_status (systemctl is-active sshd 2>/dev/null); test -z "$ssh_status" && set ssh_status "n/a"
        set -l fw_status (systemctl is-active firewalld 2>/dev/null); test -z "$fw_status" && set fw_status "n/a"
        set -l fail2ban (systemctl is-active fail2ban 2>/dev/null); test -z "$fail2ban" && set fail2ban "n/a"
        set -l open_ports (ss -tuln 2>/dev/null | grep LISTEN | wc -l | string trim)
        set -l last_login (last -1 -R $user 2>/dev/null | head -1 | awk '{print $4" "$5" "$6}')
        test -z "$last_login" && set last_login "n/a"

        # ASCII Art Banner
        echo
        set_color --bold cyan
        echo "    ███████╗██╗███████╗██╗  ██╗"
        echo "    ██╔════╝██║██╔════╝██║  ██║"
        echo "    █████╗  ██║███████╗███████║"
        echo "    ██╔══╝  ██║╚════██║██╔══██║"
        echo "    ██║     ██║███████║██║  ██║"
        echo "    ╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝"
        set_color normal
        echo

        # Header bar with profile name
        set_color --bold blue
        printf "  ╭───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮\n"
        printf "  │ "; set_color --bold white; printf "%s" $user; set_color brblack; printf "@"; set_color --bold green; printf "%-18s" $host
        set_color brblack; printf "│ "; set_color cyan; printf "%-17s" $datetime
        set_color brblack; printf "│ "; set_color yellow; printf "Profile: %-12s" $profile
        set_color brblack; printf "│ "; set_color magenta; printf "%-18s" "$os $kernel_short"; set_color --bold blue; printf "│\n"
        printf "  ╰───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        set_color normal
        echo

        # ROW 1: HARDWARE | OS (MAGENTA)
        set_color --bold magenta
        printf "  ┌─ HARDWARE ─────────────────────────────────────┐ ┌─ SYSTEM ──────────────────────────────────────┐\n"
        set_color normal
        printf "  │ "; set_color magenta; printf "CPU    "; set_color normal; printf "%-40s" "$cpu_name"; printf "│ │ "; set_color magenta; printf "OS     "; set_color normal; printf "%-39s" "$os $kernel_short"; printf "│\n"
        printf "  │ "; set_color magenta; printf "Cores  "; set_color normal; printf "%-40s" "$cpu_cores @ $cpu_freq MHz"; printf "│ │ "; set_color magenta; printf "Host   "; set_color normal; printf "%-39s" (string sub -l 39 "$hostname_full"); printf "│\n"
        printf "  │ "; set_color magenta; printf "GPU    "; set_color normal; printf "%-40s" "$gpu"; printf "│ │ "; set_color magenta; printf "Kernel "; set_color normal; printf "%-39s" "$kernel"; printf "│\n"
        printf "  │ "; set_color magenta; printf "RAM    "; set_color normal; printf "%-40s" "$mem_info ($mem_perc%)"; printf "│ │ "; set_color magenta; printf "DE     "; set_color normal; printf "%-39s" "$de"; printf "│\n"
        printf "  │ "; set_color magenta; printf "Disk   "; set_color normal; printf "%-40s" "$disk_info ($disk_perc%)"; printf "│ │ "; set_color magenta; printf "Shell  "; set_color normal; printf "%-39s" "$shell"; printf "│\n"
        set_color --bold magenta
        printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
        set_color normal
        echo

        # ROW 2: NETWORK | SECURITY (YELLOW)
        set_color --bold yellow
        printf "  ┌─ NETWORK ──────────────────────────────────────┐ ┌─ SECURITY STATUS ────────────────────────────┐\n"
        set_color normal
        printf "  │ "; set_color yellow; printf "IP-Pub "; set_color normal; printf "%-40s" "$ip_addr"; printf "│ │ "; set_color yellow; printf "SSH      "; set_color normal; printf "%-37s" "$ssh_status"; printf "│\n"
        printf "  │ "; set_color yellow; printf "IP-Priv"; set_color normal; printf " %-39s" "$ip_priv"; printf "│ │ "; set_color yellow; printf "Firewall "; set_color normal; printf "%-37s" "$fw_status"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Load   "; set_color normal; printf "%-40s" "$load_avg"; printf "│ │ "; set_color yellow; printf "Fail2ban "; set_color normal; printf "%-37s" "$fail2ban"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Uptime "; set_color normal; printf "%-40s" "$uptime_str"; printf "│ │ "; set_color yellow; printf "Ports    "; set_color normal; printf "%-37s" "$open_ports listening"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Pkgs   "; set_color normal; printf "%-40s" "$pkgs packages"; printf "│ │ "; set_color yellow; printf "Last     "; set_color normal; printf "%-37s" "$last_login"; printf "│\n"
        set_color --bold yellow
        printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
        set_color normal
        echo

        # ══════════════════ Tree ══════════════════
        set_color --bold blue; echo "── Tree ───────────────────────────────────────────────────────────────────────────────────────"
        set_color normal
        set_color blue; echo -n "  ~/Mounts/Git/"; set_color normal
        echo ""
        printf "    "
        for d in front cloud vault unix tools cloud-data front-data
          if test -d "$HOME/Mounts/Git/$d"
            set_color green; printf "%-14s" "$d/"
          else
            set_color red; printf "%-14s" "$d/"
          end
        end
        set_color normal; echo ""
        set_color blue; echo -n "  ~/Mounts/Storage/"; set_color normal
        echo ""
        printf "    "
        for d in Gdrive_dnm Gdrive_me
          if test -d "$HOME/Mounts/Storage/$d"
            set_color green; printf "%-14s" "$d/"
          else
            set_color red; printf "%-14s" "$d/"
          end
        end
        set_color normal; echo ""; echo ""

        # ══════════════════ Env Vars ══════════════════
        set_color --bold yellow; echo "── Env Vars ───────────────────────────────────────────────────────────────────────────────────"
        set_color normal
        set_color blue; echo -n "  Shell:         "; set_color normal
        for v in EDITOR VISUAL PAGER LANG LC_ALL MANPAGER
          if set -q $v; set_color --dim green; else; set_color --dim red; end
          printf "%-16s" "$v"
        end
        set_color normal; echo ""
        set_color blue; echo -n "  AI / LLM:      "; set_color normal
        for v in ANTHROPIC_API_KEY OPENAI_BASE_URL OPENAI_API_KEY
          if set -q $v; set_color --dim green; else; set_color --dim red; end
          printf "%-22s" "$v"
        end
        set_color normal; echo ""
        set_color blue; echo -n "  Auth:          "; set_color normal
        for v in AUTHELIA_OIDC_CLIENT_ID AUTHELIA_TOKEN_URL
          if set -q $v; set_color --dim green; else; set_color --dim red; end
          printf "%-26s" "$v"
        end
        set_color normal; echo ""
        set_color blue; echo -n "                 "; set_color normal
        for v in AUTHELIA_OIDC_CREDENTIALS_DIR AUTHELIA_OIDC_TOKENS_DIR
          if set -q $v; set_color --dim green; else; set_color --dim red; end
          printf "%-34s" "$v"
        end
        set_color normal; echo ""
        set_color blue; echo -n "  Dev:           "; set_color normal
        for v in CARGO_HOME GOPATH PIP_CACHE_DIR npm_config_cache npm_config_prefix
          if set -q $v; set_color --dim green; else; set_color --dim red; end
          printf "%-18s" "$v"
        end
        set_color normal; echo ""
        set_color blue; echo -n "  System:        "; set_color normal
        for v in DEVICE HM_PROFILE BUILDSH_GUARDRAIL TF_PLUGIN_CACHE_DIR GNUPGHOME GIT_EDITOR
          if set -q $v; set_color --dim green; else; set_color --dim red; end
          printf "%-16s" "$v"
        end
        set_color normal; echo ""
        set_color --dim; echo "    ('hhelp envvar' — list all env vars with values)"; set_color normal
        echo ""

        # ══════════════════ Configuration ══════════════════
        set_color --bold magenta; echo "── Configuration ──────────────────────────────────────────────────────────────────────────────"
        set_color normal
        # Flakes
        set_color cyan; echo "  Flakes:"
        set_color normal
        set_color magenta; echo -n "    NixOS            "; set_color normal; echo "~/Mounts/Git/unix/aa_nixos-surface_host/"
        set_color magenta; echo -n "    OS Modules       "; set_color normal; echo "~/Mounts/Git/unix/aa_nixos-surface_host/src/modules/"
        set_color magenta; echo -n "    Home-Manager     "; set_color normal; echo "~/Mounts/Git/unix/ba_flakes_desktop/"
        set_color magenta; echo -n "    HM Modules       "; set_color normal; echo "~/Mounts/Git/unix/ba_flakes_desktop/src/modules/"
        # Wrappers - Guardrails
        set_color cyan; echo "  Wrappers - Guardrails:"
        set_color normal
        set_color red; echo -n "    BLOCKED          "; set_color normal; echo "rm -rf /, mkfs, dd (always denied)"
        set_color yellow; echo -n "    CONFIRM          "; set_color normal; echo "npm npx docker nix pip apt pkg (ask before run)"
        set_color blue; echo -n "    WARNING          "; set_color normal; echo "bun cargo go (warn on write ops)"
        # Wrappers - Custom
        set_color cyan; echo "  Wrappers - Custom:"
        set_color normal
        set_color green; echo -n "    curl/wget        "; set_color normal; echo "Auto-inject Authelia token for *.diegonmarcos.com"
        set_color --dim; echo "    ('hhelp config' — cat flake.nix)"; set_color normal
        echo ""

        # ══════════════════ Tools ══════════════════
        set_color --bold green; echo "── Tools ──────────────────────────────────────────────────────────────────────────────────────"
        set_color normal
        # Nix Flakes
        set_color cyan; echo "  Nix Flakes:"
        set_color normal
        set_color magenta; echo -n "    up               "; set_color normal; echo "Rebuild Nix config"
        set_color magenta; echo -n "    conf             "; set_color normal; echo "Edit flake.nix"
        # Dev
        set -l _claude_ver (claude --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
        set -l _goose_ver (goose --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
        set_color cyan; echo "  Dev:"
        set_color normal
        set_color green; echo -n "    claude           "; set_color normal; echo "Launch Claude Code (v$_claude_ver)"
        set_color green; echo -n "    ai-cli           "; set_color normal; echo -n "Goose AI (v$_goose_ver) "; set_color --dim; echo "default: Haiku 4.5 · ai-cli -h for models"; set_color normal
        set_color green; echo -n "    code             "; set_color normal; echo "VS Code Server (local/lan/stop)"
        # Cloud
        set_color cyan; echo "  Cloud:"
        set_color normal
        set_color red; echo -n "    connect          "; set_color normal; echo "Cloud Connect Unified dashboard (git/mounts/sync/servers)"
        set_color red; echo -n "    sync             "; set_color normal; echo "File sync & serve (WebDAV SFTP HTTP+Eruda)"
        # http-dev status
        if systemctl --user is-active http-dev.service >/dev/null 2>&1
          set -l _httpd_pid (systemctl --user show http-dev.service -p MainPID --value 2>/dev/null)
          set_color green; echo -n "    http-dev         "; set_color normal; echo -n "● Web+MD+Eruda "; set_color cyan; echo -n "http://127.0.0.1:$__httpd_port"; set_color normal; echo " (PID: $_httpd_pid)"
        else
          set_color red; echo -n "    http-dev         "; set_color normal; echo "○ Not running"
        end
        # System
        set_color cyan; echo "  System:"
        set_color normal
        set_color magenta; echo -n "    tree             "; set_color normal; echo "Directory tree"
        set_color magenta; echo -n "    yazi             "; set_color normal; echo "Terminal file manager"
        set_color magenta; echo -n "    carbonyl         "; set_color normal; echo "Chromium browser in the terminal"
        set_color magenta; echo -n "    nmtui            "; set_color normal; echo "Network Manager TUI (WiFi, VPN, connections)"
        # Search (fzf)
        set_color cyan; echo "  Search (fzf):"
        set_color normal
        set_color blue; echo -n "    Ctrl+T           "; set_color normal; echo "Find file"
        set_color blue; echo -n "    Ctrl+R           "; set_color normal; echo "Search history"
        set_color blue; echo -n "    Alt+C            "; set_color normal; echo "Cd to folder"
        echo ""
        set_color --dim; echo "    ('hhelp tools' — all binaries declared in flake)"; set_color normal
        echo ""

        # ══════════════════ Alias/Functions ══════════════════
        set_color --bold yellow; echo "── Alias/Functions ────────────────────────────────────────────────────────────────────────────"
        set_color normal
        # Git
        set_color cyan; echo "  Git:"
        set_color normal
        set_color yellow; echo -n "    gacp             "; set_color normal; echo "git add . && commit && push"
        set_color yellow; echo -n "    gcl              "; set_color normal; echo "git clone <url>"
        # Others
        set_color cyan; echo "  Others:"
        set_color normal
        set_color yellow; echo -n "    hhelp            "; set_color normal; echo "Parse flake configs (config/tools/alias)"
        echo ""
        set_color --dim; echo "    ('hhelp alias' — all functions and aliases in bash and fish)"; set_color normal

        set_color cyan; echo ""
        echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
        set_color normal
      '';

      hhelp = ''
        set -l nixos_dir "$HOME/Mounts/Git/unix/aa_nixos-surface_host/src"
        set -l flake_dir "$HOME/Mounts/Git/unix/ba_flakes_desktop/src"
        set -l profiles_dir "$flake_dir/modules/profiles"
        set -l shells_dir "$flake_dir/modules/programs/shells"

        if test (count $argv) -eq 0
          set_color --bold cyan; echo "hhelp — Home-Manager flake inspector"; set_color normal
          echo ""

          # Flake info
          set_color --bold yellow; echo "  Flakes:"; set_color normal
          set_color magenta; printf "    NixOS Host       "; set_color normal
          if test -d "$nixos_dir"
            set -l nixos_rev (git -C "$nixos_dir/.." rev-parse --short HEAD 2>/dev/null; or echo "?")
            set -l nixos_dirty (git -C "$nixos_dir/.." diff --quiet 2>/dev/null; and echo ""; or echo " *dirty*")
            echo "~/Mounts/Git/unix/aa_nixos-surface_host/  ($nixos_rev$nixos_dirty)"
          else
            echo "(not found)"
          end
          set_color magenta; printf "    Home-Manager     "; set_color normal
          if test -d "$flake_dir"
            set -l hm_rev (git -C "$flake_dir/.." rev-parse --short HEAD 2>/dev/null; or echo "?")
            set -l hm_dirty (git -C "$flake_dir/.." diff --quiet 2>/dev/null; and echo ""; or echo " *dirty*")
            set -l hm_gen "?"
            if test -L "$HOME/.local/state/nix/profiles/home-manager"
              set hm_gen (readlink "$HOME/.local/state/nix/profiles/home-manager" 2>/dev/null | string replace -r '.*-(\d+)-link' '$1')
            end
            echo "~/Mounts/Git/unix/ba_flakes_desktop/  ($hm_rev$hm_dirty) gen $hm_gen"
          else
            echo "(not found)"
          end
          set_color magenta; printf "    Profile          "; set_color normal; echo "$HM_PROFILE"
          echo ""

          set_color yellow; echo "  Commands:"; set_color normal
          echo "    hhelp config             Show flake.nix + common.nix (imports, session vars, paths)"
          echo "    hhelp tools              List all packages declared in profile modules"
          echo "    hhelp alias              List all shell functions and aliases (fish + bash + zsh)"
          echo "    hhelp envvar             List all env vars with current values"
          echo "    hhelp profiles           List profile modules with descriptions"
          echo "    hhelp grep <pattern>     Search across all flake source files"
          return 0
        end

        switch $argv[1]
          case config
            set_color --bold cyan; echo "═══ Flake Configuration ═══"; set_color normal; echo ""

            # Main flake.nix
            set_color --bold yellow; echo "── flake.nix ──"; set_color normal
            if test -f "$flake_dir/flake.nix"
              command cat "$flake_dir/flake.nix"
            else
              echo "  (not found)"
            end
            echo ""

            # Common.nix (imports, session vars, paths)
            set_color --bold yellow; echo "── common.nix (imports + session) ──"; set_color normal
            if test -f "$flake_dir/modules/common.nix"
              command cat "$flake_dir/modules/common.nix"
            end

          case tools
            set_color --bold cyan; echo "═══ Declared Packages (by profile) ═══"; set_color normal; echo ""

            for pfile in $profiles_dir/*.nix
              set -l pname (basename $pfile)
              set -l pdesc (command head -1 "$pfile" 2>/dev/null | command sed 's/^# //')
              set_color --bold green; printf "── %s " "$pname"; set_color --dim; echo "($pdesc)"; set_color normal
              # Extract "pkgname  # comment" lines, format as table
              command awk '
                /^\s*#/ { next }
                /^\s*\];/ { next }
                /^\s*home\.packages/ { next }
                /^\s*\(/ { next }
                /^\s*with pkgs/ { next }
                /^\s*customPkgs/ {
                  pkg = $1; sub(/;.*/, "", pkg)
                  comment = ""
                  if (match($0, /#(.*)/, m)) comment = m[1]
                  gsub(/^\s+/, "", comment)
                  printf "  %-28s %s\n", pkg, comment
                  next
                }
                /^\s+[a-zA-Z]/ {
                  pkg = $1; sub(/;.*/, "", pkg)
                  comment = ""
                  if (match($0, /#(.*)/, m)) comment = m[1]
                  gsub(/^\s+/, "", comment)
                  if (pkg !~ /^(home|lib|config|pkgs|let|in|inherit)/)
                    printf "  %-28s %s\n", pkg, comment
                }
              ' "$pfile" 2>/dev/null
              echo ""
            end

            # Custom packages
            set_color --bold green; echo "── Custom packages (pkgs/) ──"; set_color normal
            for pkg in $flake_dir/pkgs/*.nix
              test -f "$pkg"; or continue
              set -l desc (command grep -m1 'description' "$pkg" 2>/dev/null | command sed 's/.*"\(.*\)".*/\1/')
              printf "  %-28s %s\n" (basename $pkg .nix) "$desc"
            end

          case envvar
            set -l _vars EDITOR VISUAL PAGER LANG LC_ALL MANPAGER LESS ANTHROPIC_API_KEY OPENAI_BASE_URL OPENAI_API_KEY OLLAMA_HOST AUTHELIA_OIDC_CLIENT_ID AUTHELIA_TOKEN_URL AUTHELIA_OIDC_CREDENTIALS_DIR AUTHELIA_OIDC_TOKENS_DIR CARGO_HOME GOPATH PIP_CACHE_DIR npm_config_cache npm_config_prefix COREPACK_ENABLE_AUTO_PIN DEVICE HM_PROFILE BUILDSH_GUARDRAIL TF_PLUGIN_CACHE_DIR GNUPGHOME GIT_EDITOR RUSTUP_HOME PYTHONPATH JUPYTER_CONFIG_DIR STARSHIP_SHELL FZF_DEFAULT_COMMAND

            # TABLE 1: Declarations (raw values as declared)
            set_color --bold cyan; echo "═══ Declared Values ═══"; set_color normal; echo ""
            for v in $_vars
              if set -q $v
                set_color green; printf "  %-34s = " "$v"; set_color --dim; echo "$$v"; set_color normal
              else
                set_color red; printf "  %-34s = " "$v"; echo "(not set)"; set_color normal
              end
            end

            echo ""
            # TABLE 2: Resolved (cat files, ls dirs, mask secrets)
            set_color --bold cyan; echo "═══ Resolved ═══"; set_color normal; echo ""
            set -l _secrets ANTHROPIC_API_KEY OPENAI_API_KEY
            for v in $_vars
              if not set -q $v; continue; end
              set -l val $$v
              # Mask secrets
              if contains $v $_secrets
                set_color yellow; printf "  %-34s" "$v"; set_color --dim; echo (string sub -l 8 -- "$val")"...(masked)"
                set_color normal; continue
              end
              # Resolve paths
              if string match -qr '^/' -- "$val"
                if test -L "$val"
                  # Symlink — show target and cat
                  set -l target (readlink -f "$val" 2>/dev/null)
                  set_color cyan; printf "  %-34s" "$v"; set_color --dim; echo "→ $target"
                  if test -f "$target"
                    set_color --dim; printf "  %-34s" ""; echo "  "(command head -1 "$target" 2>/dev/null | string sub -l 70)
                  end
                  set_color normal
                else if test -d "$val"
                  # Directory — ls
                  set -l items (command ls "$val" 2>/dev/null | head -8 | string join "  ")
                  set_color cyan; printf "  %-34s" "$v"; set_color --dim; echo "→ ls: $items"
                  set_color normal
                else if test -f "$val"
                  # File — cat first line
                  set -l line (command head -1 "$val" 2>/dev/null | string sub -l 70)
                  set_color cyan; printf "  %-34s" "$v"; set_color --dim; echo "→ cat: $line"
                  set_color normal
                else
                  # Path doesn't exist
                  set_color red; printf "  %-34s" "$v"; echo "→ path not found: $val"
                  set_color normal
                end
              end
            end

          case alias
            set_color --bold cyan; echo "═══ Shell Functions & Aliases ═══"; set_color normal; echo ""

            # Fish shellAbbrs (abbreviations)
            set_color --bold yellow; echo "── Fish abbreviations (fish.nix shellAbbrs) ──"; set_color normal
            command awk '
              /shellAbbrs\s*=\s*\{/ { inside=1; next }
              inside && /^\s*\};/ { inside=0; next }
              inside && /^\s+\w+ = "/ {
                line = $0
                gsub(/^\s+/, "", line)
                split(line, parts, " = ")
                name = parts[1]
                val = parts[2]
                gsub(/";.*/, "", val)
                gsub(/"/, "", val)
                printf "  %-20s %s\n", name, val
              }
            ' "$shells_dir/fish.nix" 2>/dev/null
            echo ""

            # Fish shellAliases
            set_color --bold yellow; echo "── Fish aliases (fish.nix shellAliases) ──"; set_color normal
            command awk '
              /shellAliases\s*=\s*\{/ { inside=1; next }
              inside && /^\s*\};/ { inside=0; next }
              inside && /^\s+\w+ = "/ {
                line = $0
                gsub(/^\s+/, "", line)
                split(line, parts, " = ")
                name = parts[1]
                val = parts[2]
                gsub(/";.*/, "", val)
                gsub(/"/, "", val)
                printf "  %-20s %s\n", name, val
              }
            ' "$shells_dir/fish.nix" 2>/dev/null
            echo ""

            # Fish functions (multiline — just list names)
            set_color --bold yellow; echo "── Fish functions (fish.nix) ──"; set_color normal
            command awk '
              /^\s*functions\s*=\s*\{/ { inside=1; next }
              inside && /^\s*\};/ { inside=0; next }
              inside && /^\s+\w+ = / {
                name = $1
                if (name !~ /^(fish_greeting|enable)/)
                  printf "  %s\n", name
              }
            ' "$shells_dir/fish.nix" 2>/dev/null
            echo ""

            # Bash aliases
            set_color --bold yellow; echo "── Bash aliases (bash.nix) ──"; set_color normal
            if test -f "$shells_dir/bash.nix"
              command awk '
                /shellAliases\s*=\s*\{/ { inside=1; next }
                inside && /^\s*\};/ { inside=0; next }
                inside && /^\s+\w+ = "/ {
                  line = $0
                  gsub(/^\s+/, "", line)
                  split(line, parts, " = ")
                  name = parts[1]
                  val = parts[2]
                  gsub(/";.*/, "", val)
                  gsub(/"/, "", val)
                  printf "  %-20s %s\n", name, val
                }
              ' "$shells_dir/bash.nix" 2>/dev/null
            end
            echo ""

            # Zsh aliases
            set_color --bold yellow; echo "── Zsh aliases (zsh.nix) ──"; set_color normal
            if test -f "$shells_dir/zsh.nix"
              command awk '
                /shellAliases\s*=\s*\{/ { inside=1; next }
                inside && /^\s*\};/ { inside=0; next }
                inside && /^\s+\w+ = "/ {
                  line = $0
                  gsub(/^\s+/, "", line)
                  split(line, parts, " = ")
                  name = parts[1]
                  val = parts[2]
                  gsub(/";.*/, "", val)
                  gsub(/"/, "", val)
                  printf "  %-20s %s\n", name, val
                }
              ' "$shells_dir/zsh.nix" 2>/dev/null
            end

          case profiles
            set_color --bold cyan; echo "═══ Profile Modules ═══"; set_color normal; echo ""
            for pfile in $profiles_dir/*.nix
              set -l pname (basename $pfile .nix)
              set -l desc (command head -1 "$pfile" 2>/dev/null | command sed 's/^# //')
              set -l pkgcount (command grep -cE '^\s+pkgs\.|^\s+[a-z].*$' "$pfile" 2>/dev/null; or echo 0)
              printf "  %-30s %s\n" "$pname" "$desc"
            end

          case grep
            if test (count $argv) -lt 2
              echo "Usage: hhelp grep <pattern>"
              return 1
            end
            set_color --bold cyan; echo "═══ Search: $argv[2] ═══"; set_color normal; echo ""
            command grep -rn --color=always "$argv[2]" "$flake_dir" 2>/dev/null \
              | command sed "s|$flake_dir/||"

          case '*'
            echo "Unknown command: $argv[1]"
            echo "Run 'hhelp' for usage"
            return 1
        end
      '';

      mkcd = "mkdir -p $argv[1]; and cd $argv[1]";
      mkd = "mkdir -p $argv; and cd $argv[-1]";

      extract = ''
        if test -f $argv[1]
          switch $argv[1]
            case '*.tar.bz2'
              tar xjf $argv[1]
            case '*.tar.gz'
              tar xzf $argv[1]
            case '*.tar.xz'
              tar xJf $argv[1]
            case '*.tar.zst'
              unzstd $argv[1]
            case '*.bz2'
              bunzip2 $argv[1]
            case '*.gz'
              gunzip $argv[1]
            case '*.tar'
              tar xf $argv[1]
            case '*.zip'
              unzip $argv[1]
            case '*.7z'
              7z x $argv[1]
            case '*.deb'
              ar x $argv[1]
            case '*.rar'
              unrar x $argv[1]
            case '*'
              echo "'$argv[1]' cannot be extracted"
          end
        end
      '';

      qfind = "command find . -name \"*$argv[1]*\"";

      backup = ''
        if test -f $argv[1]
          set -l timestamp (date +%Y%m%d_%H%M%S)
          cp $argv[1] "$argv[1].backup.$timestamp"
          echo "Backup created: $argv[1].backup.$timestamp"
        else
          echo "File not found: $argv[1]"
        end
      '';

      git_current_branch = "git branch 2>/dev/null | sed -n '/\\* /s///p'";
      gcam = "git add --all; and git commit -m $argv[1]";
      gpsh = "git push origin (git_current_branch)";
      gacp = "git add --all; and git commit -m $argv[1]; and git push";

      cpucap = ''
        for i in /sys/devices/system/cpu/cpu[0-9]*/cpufreq
          if test -d "$i"
            set -l cur (cat "$i/scaling_cur_freq" 2>/dev/null)
            set -l max (cat "$i/scaling_max_freq" 2>/dev/null)
            if test -n "$cur" -a -n "$max"
              set -l core (basename (dirname "$i"))
              printf "%s: %4d MHz / %4d MHz = %3d%%\n" $core (math "$cur / 1000") (math "$max / 1000") (math "$cur * 100 / $max")
            end
          end
        end
      '';

      serve = "http-dev start $argv";

      duh = "command du -h --max-depth=1 | sort -h";

      localip = "ip addr show | grep 'inet ' | grep -v 127.0.0.1 | awk '{print \$2}'";

      hg = "history | grep $argv";

      myhelp = ''
        printf "\n\033[1;32m=== QUICK REFERENCE ===\033[0m\n"
        echo "Navigation:  ..  ...  ....  mkcd <dir>"
        echo "Listing:     ll  la  lh  lt"
        echo "Git:         gs  ga  gc  gp  gl  gd  gcam  gpsh"
        echo "Docker:      dps  dpsa  dcu  dcd  dlog  dex"
        echo "System:      df  free  ports  myip  cpucap"
        echo "Tools:       extract  backup  qfind  serve  duh"
      '';

      # Search available commands with fzf (Ctrl+P)
      __fzf_search_commands = ''
        set -l cmd (begin
          # Get all commands from PATH
          for dir in $PATH
            if test -d $dir
              command ls -1 $dir 2>/dev/null
            end
          end
          # Also include fish functions and builtins
          functions -n
          builtin -n
        end | sort -u | fzf --height 40% --reverse --border --prompt="Commands> ")
        if test -n "$cmd"
          commandline -i $cmd
        end
        commandline -f repaint
      '';

    };

    interactiveShellInit = ''
      # NODE_PATH for shared ~/.node_modules (ESM doesn't read NODE_PATH, but CJS + tsx do)
      set -gx NODE_PATH "$HOME/.node_modules/node_modules"

      # Starship prompt
      if command -v starship &>/dev/null
        starship init fish | source
      end

      # Zoxide
      if command -v zoxide &>/dev/null
        zoxide init fish | source
      end

      # FZF
      if command -v fzf &>/dev/null
        fzf --fish | source
      end

      # Direnv
      if command -v direnv &>/dev/null
        direnv hook fish | source
      end

      # API keys from vault (read at shell init, not baked into Nix store)
      if test -f ~/git/vault/A0_keys/providers/anthropic/api-key_opaque
        set -gx ANTHROPIC_API_KEY (cat ~/git/vault/A0_keys/providers/anthropic/api-key_opaque)
      end

      # Vi mode
      fish_vi_key_bindings

      # Keybinding: Ctrl+P to search available commands with fzf
      bind \cp '__fzf_search_commands'
      bind -M insert \cp '__fzf_search_commands'

      # NVM via bass (if available)
      # set -gx NVM_DIR $HOME/.nvm

      # Ensure user PATH entries are set even when __HM_SESS_VARS_SOURCED is
      # inherited from a parent process (e.g. Plasma → Konsole).
      # fish_add_path is idempotent: no duplicates added.
      if test -d /mnt/shared/tools/scripts
        fish_add_path /mnt/shared/tools/scripts
      end
      for dir in /mnt/shared/tools/devops/bin /mnt/shared/tools/data/bin /mnt/shared/tools/dev/bin /mnt/shared/tools/base/bin
        if test -d $dir
          fish_add_path $dir
        end
      end
      if test -d $HOME/.npm-global/bin
        fish_add_path $HOME/.npm-global/bin
      end
      if test -d $HOME/.cargo/bin
        fish_add_path $HOME/.cargo/bin
      end
      if test -d $HOME/.local/bin
        fish_add_path $HOME/.local/bin
      end
      # nix-profile must come LAST so it has highest PATH priority
      # (patchelf'd binaries like claude-code override unpatched npm/cargo copies)
      if test -d $HOME/.nix-profile/bin
        fish_add_path $HOME/.nix-profile/bin
      end

      # Authelia OIDC credentials (vault paths)
      set -gx AUTHELIA_OIDC_CREDENTIALS_DIR "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials"
      set -gx AUTHELIA_OIDC_TOKENS_DIR "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens"
      set -gx AUTHELIA_OIDC_CLIENT_ID "claude-admin"
      set -gx AUTHELIA_TOKEN_URL "https://auth.diegonmarcos.com/api/oidc/token"

      # http-dev runs as systemd user service (not per-shell)
      set -g __httpd_port 8000

      # Local overrides
      if test -f ~/.config/fish/config.local.fish
        source ~/.config/fish/config.local.fish
      end
    '';
  };
}
