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

      # Session (Plasma 6)
      logout = "killall -9 -u $USER; qdbus org.kde.Shutdown /Shutdown logout";
      reboot = "qdbus org.kde.Shutdown /Shutdown logoutAndReboot";
      poweroff = "qdbus org.kde.Shutdown /Shutdown logoutAndShutdown";

      # Browser dev
      chrome_no_CORS = "chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors";

      # Custom tools
      gdrive = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh";

      # Welcome screen
      welcome = "_show_welcome";
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

      _show_welcome = ''
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
        set -l ip_addr (ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        set -l load_avg (command cat /proc/loadavg | awk '{print $1" "$2" "$3}')
        set -l pkgs (command ls /nix/store 2>/dev/null | wc -l | string trim)
        set -l procs (command ls /proc 2>/dev/null | grep -c '^[0-9]')
        set -l datetime (date '+%d-%m-%Y %H:%M')
        set -l gpu (lspci 2>/dev/null | grep -i vga | sed 's/.*: //' | string sub -l 25)
        set -l node_ver (node --version 2>/dev/null | tr -d 'v'); test -z "$node_ver" && set node_ver "-"

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

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 1: HARDWARE | OS (MAGENTA)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
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

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 2: NETWORK | SECURITY (YELLOW)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        set_color --bold yellow
        printf "  ┌─ NETWORK ──────────────────────────────────────┐ ┌─ SECURITY STATUS ────────────────────────────┐\n"
        set_color normal
        printf "  │ "; set_color yellow; printf "IP     "; set_color normal; printf "%-40s" "$ip_addr"; printf "│ │ "; set_color yellow; printf "SSH      "; set_color normal; printf "%-37s" "$ssh_status"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Load   "; set_color normal; printf "%-40s" "$load_avg"; printf "│ │ "; set_color yellow; printf "Firewall "; set_color normal; printf "%-37s" "$fw_status"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Uptime "; set_color normal; printf "%-40s" "$uptime_str"; printf "│ │ "; set_color yellow; printf "Fail2ban "; set_color normal; printf "%-37s" "$fail2ban"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Pkgs   "; set_color normal; printf "%-40s" "$pkgs packages"; printf "│ │ "; set_color yellow; printf "Ports    "; set_color normal; printf "%-37s" "$open_ports listening"; printf "│\n"
        printf "  │ "; set_color yellow; printf "Procs  "; set_color normal; printf "%-40s" "$procs running"; printf "│ │ "; set_color yellow; printf "Last     "; set_color normal; printf "%-37s" "$last_login"; printf "│\n"
        set_color --bold yellow
        printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
        set_color normal
        echo

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 3: DEV ENV - Languages | Containers | SDKs (GREEN)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        set rust_v (rustc --version 2>/dev/null | awk '{print $2}'); test -z "$rust_v" && set rust_v "-"
        set go_v (go version 2>/dev/null | awk '{gsub(/go/,"",$3); print $3}'); test -z "$go_v" && set go_v "-"
        set py_v (python3 --version 2>/dev/null | awk '{print $2}'); test -z "$py_v" && set py_v "-"
        set gcc_v (gcc --version 2>/dev/null | head -1 | awk '{print $NF}'); test -z "$gcc_v" && set gcc_v "-"
        set java_v (java --version 2>/dev/null | head -1 | awk '{print $2}'); test -z "$java_v" && set java_v "-"

        set_color --bold green
        printf "  ┌─ LANGUAGES ────────────────────┐ ┌─ CONTAINERS ────────────────────┐ ┌─ SDKs & CLOUD ────────────────┐\n"
        set_color green
        printf "  │ %-10s %-10s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-10s %-8s │\n" "rust" "go" "python" "podman" "buildah" "skopeo" "aws" "gcloud" "azure"
        printf "  │ %-10s %-10s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-10s %-8s │\n" "$rust_v" "$go_v" "$py_v" "kubectl" "helm" "k9s" "terraform" "pulumi" "oci-cli"
        printf "  │ %-10s %-10s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-10s %-8s │\n" "node" "gcc" "java" "compose" "kind" "minikube" "firebase" "supabase" "netlify"
        printf "  │ %-10s %-10s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-10s %-8s │\n" "$node_ver" "$gcc_v" "$java_v" "ansible" "sops" "vault" "vercel" "fly.io" "railway"
        set_color --bold green
        printf "  └──────────────────────────────────┘ └──────────────────────────────────┘ └────────────────────────────────┘\n"
        set_color normal
        echo

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 4: SHELL - Aliases | Functions | Keybindings (CYAN)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        set_color --bold cyan
        printf "  ┌─ ALIASES ────────────────────────┐ ┌─ FUNCTIONS ────────────────────┐ ┌─ KEYBINDINGS ────────────────┐\n"
        set_color cyan
        printf "  │ %-6s %-6s %-6s %-6s %-6s │ │ %-10s %-19s │ │ %-10s %-17s │\n" "ll" "la" "lt" "lh" "tree" "mkcd" "create & cd dir" "Ctrl+R" "fzf history"
        printf "  │ %-6s %-6s %-6s %-6s %-6s │ │ %-10s %-19s │ │ %-10s %-17s │\n" "gs" "ga" "gc" "gp" "gl" "extract" "unpack archive" "Ctrl+T" "fzf files"
        printf "  │ %-6s %-6s %-6s %-6s %-6s │ │ %-10s %-19s │ │ %-10s %-17s │\n" ".." "..." "...." "z" "c" "backup" "timestamped copy" "Alt+C" "fzf cd dir"
        printf "  │ %-6s %-6s %-6s %-6s %-6s │ │ %-10s %-19s │ │ %-10s %-17s │\n" "df" "du" "free" "ports" "myip" "serve" "start http server" "Ctrl+P" "fzf commands"
        set_color --bold cyan
        printf "  └────────────────────────────────────┘ └────────────────────────────────┘ └────────────────────────────────┘\n"
        set_color normal
        echo

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 5: CLI TOOLS (RED)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        set_color --bold red
        printf "  ┌─ SHELL TOOLS ────────────────────┐ ┌─ BUILD & DEBUG ────────────────┐ ┌─ NETWORK & DATA ──────────────┐\n"
        set_color red
        printf "  │ %-8s %-8s %-8s %-8s │ │ %-8s %-8s %-8s %-6s │ │ %-8s %-7s %-7s %-6s │\n" "eza" "bat" "fd" "rg" "cmake" "ninja" "make" "meson" "nmap" "mtr" "curl" "wget"
        printf "  │ %-8s %-8s %-8s %-8s │ │ %-8s %-8s %-8s %-6s │ │ %-8s %-7s %-7s %-6s │\n" "fzf" "zoxide" "yazi" "btop" "gdb" "lldb" "strace" "ltrace" "httpie" "rsync" "rclone" "ssh"
        printf "  │ %-8s %-8s %-8s %-8s │ │ %-8s %-8s %-8s %-6s │ │ %-8s %-7s %-7s %-6s │\n" "ncdu" "duf" "tree" "htop" "clang" "gcc" "shfmt" "just" "jq" "yq" "sqlite" "redis"
        printf "  │ %-8s %-8s %-8s %-8s │ │ %-8s %-8s %-8s %-6s │ │ %-8s %-7s %-7s %-6s │\n" "lazygit" "gh" "delta" "difft" "pandoc" "doxygen" "meson" "ninja" "gnupg" "pass" "age" "sops"
        set_color --bold red
        printf "  └────────────────────────────────────┘ └────────────────────────────────┘ └────────────────────────────────┘\n"
        set_color normal
        echo

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 6: GUI APPS (BLUE)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
        set_color --bold blue
        printf "  ┌─ OFFICE & NOTES ─────────────────┐ ┌─ MEDIA & GRAPHICS ─────────────┐ ┌─ FILES & VIEWERS ─────────────┐\n"
        set_color blue
        printf "  │ %-11s %-11s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-9s %-9s │\n" "libreoffice" "onlyoffice" "calligra" "gimp" "krita" "inkscape" "dolphin" "ranger" "mc"
        printf "  │ %-11s %-11s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-9s %-9s │\n" "obsidian" "zettlr" "joplin" "kdenlive" "obs-studio" "shotcut" "okular" "zathura" "evince"
        printf "  │ %-11s %-11s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-9s %-9s │\n" "logseq" "notion" "typora" "vlc" "mpv" "audacity" "gwenview" "feh" "imv"
        printf "  │ %-11s %-11s %-10s │ │ %-10s %-10s %-10s │ │ %-10s %-9s %-9s │\n" "taskwarrior" "calcurse" "vit" "ffmpeg" "imagemagick" "sox" "flameshot" "peek" "maim"
        set_color --bold blue
        printf "  └────────────────────────────────────┘ └────────────────────────────────┘ └────────────────────────────────┘\n"
        set_color normal
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

      # Keybinding: Ctrl+P to search available commands with fzf
      bind \cp '__fzf_search_commands'
      bind -M insert \cp '__fzf_search_commands'

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
