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
      dps = "podman ps";
      dpsa = "podman ps -a";
      dcu = "podman-compose up";
      dcd = "podman-compose down";
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
      docker = "podman";

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

      # Browser dev
      chrome_no_CORS = "chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors";

      # Custom tools
      gdrive = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh";
    };

    functions = {
      fish_greeting = "";

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

      serve = "python3 -m http.server $argv[1]; or python3 -m http.server 8000";

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

      _show_welcome = ''
        # Gather system info (use command to bypass aliases)
        set -l user (whoami)
        set -l host (hostname -s)
        set -l os "NixOS"
        set -l kernel (uname -r | cut -d'-' -f1)
        set -l arch (uname -m)
        set -l shell "Fish $FISH_VERSION"
        set -l term "$TERM"
        set -l de "$XDG_CURRENT_DESKTOP"
        set -l uptime_secs (command cat /proc/uptime | cut -d. -f1)
        set -l uptime_days (math -s0 "$uptime_secs / 86400")
        set -l uptime_hours (math -s0 "($uptime_secs % 86400) / 3600")
        set -l uptime_mins (math -s0 "($uptime_secs % 3600) / 60")
        set -l uptime_str "$uptime_days"'d '"$uptime_hours"'h '"$uptime_mins"'m'
        set -l cpu_name (command grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //' | sed 's/(R)//g' | sed 's/(TM)//g' | cut -c1-30)
        set -l cpu_cores (nproc)
        set -l cpu_freq_raw (command cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        set -l cpu_freq (math -s0 "$cpu_freq_raw / 1000")
        set -l mem_used (command free -h | awk '/Mem:/ {print $3}')
        set -l mem_total (command free -h | awk '/Mem:/ {print $2}')
        set -l mem_perc (command free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
        set -l disk_used (command df -h /nix | awk 'NR==2 {print $3}')
        set -l disk_total (command df -h /nix | awk 'NR==2 {print $2}')
        set -l disk_perc (command df /nix | awk 'NR==2 {gsub(/%/,""); print $5}')
        set -l ip_addr (ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        set -l load_avg (command cat /proc/loadavg | awk '{print $1, $2, $3}')
        set -l pkgs (command ls /nix/store 2>/dev/null | wc -l)
        set -l procs (command ls /proc 2>/dev/null | grep -c '^[0-9]')
        set -l datetime (date '+%d-%m-%Y %H:%M:%S')
        set -l curpath (pwd | sed "s|$HOME|~|")
        set -l gpu (lspci 2>/dev/null | grep -i vga | sed 's/.*controller: //' | sed 's/ (rev .*//' | cut -c1-40)
        set -l node_ver (node --version 2>/dev/null | tr -d 'v')
        set -l python_ver (python3 --version 2>/dev/null | awk '{print $2}')
        set -l git_ver (git --version 2>/dev/null | awk '{print $3}')

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

        # Header bar
        set_color --bold blue
        printf "  ╭────────────────────────────────────────────────────────────────────╮\n"
        printf "  │"; set_color --bold white; printf " %s" $user; set_color brblack; printf "@"; set_color --bold green; printf "%s " $host
        set_color brblack; printf "│ "; set_color cyan; printf "%s " $datetime
        set_color brblack; printf "│ "; set_color yellow; printf "%-16s" (string sub -l 16 $curpath); set_color --bold blue; printf "│\n"
        printf "  ╰────────────────────────────────────────────────────────────────────╯\n"
        set_color normal
        echo

        # System Info Card
        set_color --bold yellow; printf "  ┌─ SYSTEM ─────────────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color yellow; printf "%-9s" "OS"; set_color normal; printf "%-58s" "$os $kernel ($arch)"; printf "│\n"
        printf "  │  "; set_color yellow; printf "%-9s" "HOST"; set_color normal; printf "%-58s" (hostname); printf "│\n"
        printf "  │  "; set_color yellow; printf "%-9s" "KERNEL"; set_color normal; printf "%-58s" (uname -r); printf "│\n"
        printf "  │  "; set_color yellow; printf "%-9s" "DESKTOP"; set_color normal; printf "%-58s" "$de ($term)"; printf "│\n"
        printf "  │  "; set_color yellow; printf "%-9s" "UPTIME"; set_color normal; printf "%-58s" "$uptime_str"; printf "│\n"
        set_color --bold yellow; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Hardware Card
        set_color --bold magenta; printf "  ┌─ HARDWARE ───────────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color magenta; printf "%-9s" "CPU"; set_color normal; printf "%-58s" "$cpu_name"; printf "│\n"
        printf "  │  "; set_color magenta; printf "%-9s" "CORES"; set_color normal; printf "%-58s" "$cpu_cores cores @ $cpu_freq MHz"; printf "│\n"
        printf "  │  "; set_color magenta; printf "%-9s" "GPU"; set_color normal; printf "%-58s" "$gpu"; printf "│\n"
        printf "  │  "; set_color magenta; printf "%-9s" "MEMORY"; set_color normal; printf "%-58s" "$mem_used / $mem_total ($mem_perc%)"; printf "│\n"
        printf "  │  "; set_color magenta; printf "%-9s" "DISK"; set_color normal; printf "%-58s" "$disk_used / $disk_total ($disk_perc%)"; printf "│\n"
        set_color --bold magenta; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Environment Card
        set_color --bold green; printf "  ┌─ ENVIRONMENT ────────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color green; printf "%-9s" "SHELL"; set_color normal; printf "%-58s" "$shell"; printf "│\n"
        printf "  │  "; set_color green; printf "%-9s" "PYTHON"; set_color normal; printf "%-58s" "$python_ver"; printf "│\n"
        printf "  │  "; set_color green; printf "%-9s" "NODE"; set_color normal; printf "%-58s" "$node_ver"; printf "│\n"
        printf "  │  "; set_color green; printf "%-9s" "GIT"; set_color normal; printf "%-58s" "$git_ver"; printf "│\n"
        printf "  │  "; set_color green; printf "%-9s" "PACKAGES"; set_color normal; printf "%-58s" "$pkgs (nix-store)"; printf "│\n"
        printf "  │  "; set_color green; printf "%-9s" "PROCS"; set_color normal; printf "%-58s" "$procs running"; printf "│\n"
        set_color --bold green; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Network Card
        set_color --bold blue; printf "  ┌─ NETWORK ────────────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color blue; printf "%-9s" "IP"; set_color normal; printf "%-58s" "$ip_addr"; printf "│\n"
        printf "  │  "; set_color blue; printf "%-9s" "LOAD"; set_color normal; printf "%-58s" "$load_avg"; printf "│\n"
        set_color --bold blue; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Aliases Card
        set_color --bold cyan; printf "  ┌─ ALIASES ────────────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  FILES    ll la lt lh tree       NAV       .. ... .... mkcd z        │\n"
        printf "  │  GIT      gs ga gc gp gl gd      DOCKER    dps dpsa dcu dcd dlog     │\n"
        printf "  │  SYSTEM   df free ports myip     PYTHON    py pip ppy                │\n"
        set_color --bold cyan; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Functions Card
        set_color --bold red; printf "  ┌─ FUNCTIONS ──────────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  mkcd <dir>     Create and cd         extract <file>  Unpack archive │\n"
        printf "  │  backup <file>  Timestamped copy      qfind <name>    Quick search   │\n"
        printf "  │  serve [port]   HTTP server           cpucap          CPU frequency  │\n"
        printf "  │  gcam <msg>     Git add+commit        gpsh            Push to origin │\n"
        set_color --bold red; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Tools Card
        set_color --bold white; printf "  ┌─ MODERN TOOLS ───────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  starship   Prompt             zoxide      Smart cd (z)              │\n"
        printf "  │  fzf        Fuzzy finder       direnv      Auto environments         │\n"
        printf "  │  bat        Better cat         eza         Better ls                 │\n"
        printf "  │  fd         Better find        rg          Better grep (ripgrep)     │\n"
        set_color --bold white; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # FZF Card
        set_color --bold yellow; printf "  ┌─ FZF KEYBINDINGS ────────────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  Ctrl+R     Search history     Ctrl+T      Search files (insert)     │\n"
        printf "  │  Alt+C      cd into dir        Ctrl+/      Toggle preview            │\n"
        printf "  │  Ctrl+A     Select all         Ctrl+Y      Copy to clipboard         │\n"
        set_color --bold yellow; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # Languages Card - Get versions dynamically
        set rust_v (rustc --version 2>/dev/null | awk '{print $2}'); test -z "$rust_v" && set rust_v "n/a"
        set go_v (go version 2>/dev/null | awk '{gsub(/go/,"",$3); print $3}'); test -z "$go_v" && set go_v "n/a"
        set node_v2 (node --version 2>/dev/null | tr -d 'v'); test -z "$node_v2" && set node_v2 "n/a"
        set py_v (python3 --version 2>/dev/null | awk '{print $2}'); test -z "$py_v" && set py_v "n/a"
        set gcc_v (gcc --version 2>/dev/null | head -1 | awk '{print $NF}'); test -z "$gcc_v" && set gcc_v "n/a"
        set java_v (java --version 2>/dev/null | head -1 | awk '{print $2}'); test -z "$java_v" && set java_v "n/a"
        set ruby_v (ruby --version 2>/dev/null | awk '{print $2}'); test -z "$ruby_v" && set ruby_v "n/a"
        set R_v (R --version 2>/dev/null | head -1 | awk '{print $3}'); test -z "$R_v" && set R_v "n/a"

        set_color --bold magenta; printf "  ┌─ LANGUAGES & COMPILERS ──────────────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color magenta; printf "CLI"; set_color normal; printf "  rust $rust_v    go $go_v    node $node_v2    python $py_v     │\n"
        printf "  │        gcc $gcc_v       java $java_v       ruby $ruby_v       R $R_v      │\n"
        set_color --bold magenta; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # CLI Tools Card
        set_color --bold cyan; printf "  ┌─ CLI TOOLKIT (nix-home-manager) ─────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color cyan; printf "SHELL"; set_color normal; printf "    eza bat fd rg fzf zoxide yazi btop ncdu duf jq yq gh    │\n"
        printf "  │  "; set_color cyan; printf "BUILD"; set_color normal; printf "    cmake ninja make meson gdb valgrind strace shellcheck   │\n"
        printf "  │  "; set_color cyan; printf "CLOUD"; set_color normal; printf "    podman kubectl helm k9s aws gcloud azure ansible sops   │\n"
        printf "  │  "; set_color cyan; printf "NET  "; set_color normal; printf "    nmap mtr tcpdump wireshark iftop tor wireguard httpie   │\n"
        printf "  │  "; set_color cyan; printf "DATA "; set_color normal; printf "    sqlite postgres mysql redis pgcli jupyter pandas torch  │\n"
        set_color --bold cyan; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo

        # GUI Apps Card
        set_color --bold green; printf "  ┌─ GUI APPS (nix-home-manager) ────────────────────────────────────────┐\n"; set_color normal
        printf "  │  "; set_color green; printf "OFFICE"; set_color normal; printf "   libreoffice obsidian zettlr joplin okular zathura       │\n"
        printf "  │  "; set_color green; printf "MEDIA "; set_color normal; printf "   gimp krita inkscape kdenlive obs-studio vlc mpv audacity│\n"
        printf "  │  "; set_color green; printf "FILES "; set_color normal; printf "   dolphin ranger mc digikam gwenview drawio flameshot     │\n"
        set_color --bold green; printf "  └──────────────────────────────────────────────────────────────────────┘\n"; set_color normal
        echo
      '';
    };

    interactiveShellInit = ''
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

      # Vi mode
      fish_vi_key_bindings

      # NVM via bass (if available)
      # set -gx NVM_DIR $HOME/.nvm

      # Cargo
      if test -d $HOME/.cargo/bin
        fish_add_path $HOME/.cargo/bin
      end

      # Show welcome
      _show_welcome

      # Local overrides
      if test -f ~/.config/fish/config.local.fish
        source ~/.config/fish/config.local.fish
      end
    '';
  };
}
