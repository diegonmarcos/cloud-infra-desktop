# Zsh shell configuration - Comprehensive
{ config, pkgs, lib, ... }:

{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history = {
      size = 10000;
      save = 10000;
      path = "${config.xdg.dataHome}/zsh/history";
      ignoreDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };

    shellAliases = {
      # Modern CLI replacements
      ls = "eza --color=auto --icons";
      ll = "eza -alF --icons";
      la = "eza -A --icons";
      l = "eza -CF --icons";
      lh = "eza -lh --icons";
      lt = "eza --tree --level=2 --icons";
      cat = "bat --paging=never";
      grep = "rg";
      find = "fd";

      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      "....." = "cd ../../../..";

      # Safety
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";

      # Python
      py = "python3";
      python = "python3";
      pip = "pip3";
      ppy = "poetry run python3";

      # Git shortcuts
      gs = "git status -sb";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gp = "git push";
      gl = "git log --oneline --graph --decorate -20";
      gla = "git log --oneline --graph --decorate --all";
      gd = "git diff";
      gds = "git diff --staged";
      gco = "git checkout";
      gb = "git branch";
      gba = "git branch -a";
      gpl = "git pull";
      gcl = "git clone";
      gst = "git stash";
      gstp = "git stash pop";

      # Docker/Podman
      docker = "podman";
      dc = "podman-compose";
      dps = "podman ps";
      dpsa = "podman ps -a";
      dcu = "podman-compose up";
      dcd = "podman-compose down";
      dlog = "podman logs --tail 100";
      dex = "podman exec -it";

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
      hg = "history | grep";
      path = "echo $PATH | tr ':' '\\n'";
      week = "date +%V";
      reload = "source ~/.zshrc";

      # Directory stack
      d = "dirs -v | head -10";
      "1" = "cd -";
      "2" = "cd -2";
      "3" = "cd -3";

      # Browser dev
      chrome_no_CORS = "chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors";

      # Custom tools
      gdrive = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh";

      # Welcome screen
      welcome = "_show_welcome";
    };

    initExtra = ''
      # =======================================================================
      # ZSH OPTIONS
      # =======================================================================
      setopt AUTO_CD
      setopt AUTO_PUSHD
      setopt PUSHD_IGNORE_DUPS
      setopt PUSHD_SILENT
      setopt CORRECT
      setopt EXTENDED_GLOB
      setopt NO_BEEP

      # Vi mode
      bindkey -v
      export KEYTIMEOUT=1

      # Better history search
      bindkey '^R' history-incremental-search-backward
      bindkey '^P' up-line-or-search
      bindkey '^N' down-line-or-search

      # Edit command in editor
      autoload -Uz edit-command-line
      zle -N edit-command-line
      bindkey '^X^E' edit-command-line

      # =======================================================================
      # INTEGRATIONS
      # =======================================================================

      # Starship prompt
      if command -v starship &>/dev/null; then
        eval "$(starship init zsh)"
      fi

      # Zoxide
      if command -v zoxide &>/dev/null; then
        eval "$(zoxide init zsh)"
      fi

      # FZF - handled by programs.fzf module

      # Direnv
      if command -v direnv &>/dev/null; then
        eval "$(direnv hook zsh)"
      fi

      # NVM
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

      # Cargo
      [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

      # =======================================================================
      # FUNCTIONS
      # =======================================================================

      mkcd() { mkdir -p "$1" && cd "$1"; }
      mkd() { mkdir -p "$@" && cd "''${@: -1}"; }

      extract() {
        if [[ -f "$1" ]]; then
          case "$1" in
            *.tar.bz2) tar xjf "$1" ;;
            *.tar.gz)  tar xzf "$1" ;;
            *.tar.xz)  tar xJf "$1" ;;
            *.tar.zst) unzstd "$1" ;;
            *.bz2)     bunzip2 "$1" ;;
            *.gz)      gunzip "$1" ;;
            *.tar)     tar xf "$1" ;;
            *.zip)     unzip "$1" ;;
            *.7z)      7z x "$1" ;;
            *.deb)     ar x "$1" ;;
            *.rar)     unrar x "$1" ;;
            *)         echo "'$1' cannot be extracted" ;;
          esac
        fi
      }

      qfind() { find . -name "*$1*"; }

      backup() {
        if [ -f "$1" ]; then
          cp "$1" "$1.backup.$(date +%Y%m%d_%H%M%S)"
          echo "Backup created: $1.backup.$(date +%Y%m%d_%H%M%S)"
        else
          echo "File not found: $1"
        fi
      }

      git_current_branch() { git branch 2>/dev/null | sed -n '/\* /s///p'; }
      gcam() { git add --all && git commit -m "$1"; }
      gpsh() { git push origin $(git_current_branch); }

      cpucap() {
        for i in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
          if [ -d "$i" ]; then
            cur=$(cat "$i/scaling_cur_freq" 2>/dev/null)
            max=$(cat "$i/scaling_max_freq" 2>/dev/null)
            if [ -n "$cur" ] && [ -n "$max" ]; then
              core=$(basename "$(dirname "$i")")
              printf "%s: %4d MHz / %4d MHz = %3d%%\n" "$core" $((cur/1000)) $((max/1000)) $((cur*100/max))
            fi
          fi
        done
      }

      serve() { python3 -m http.server "''${1:-8000}"; }

      duh() { command du -h --max-depth=1 | sort -h; }

      localip() { ip addr show | grep 'inet ' | grep -v 127.0.0.1 | awk '{print $2}'; }

      myhelp() {
        echo -e "\n\033[1;32m=== QUICK REFERENCE ===\033[0m"
        echo "Navigation:  ..  ...  ....  mkcd <dir>  1-5 (popd)"
        echo "Listing:     ll  la  lh  lt"
        echo "Git:         gs  ga  gc  gp  gl  gd  gcam  gpsh"
        echo "Docker:      dps  dpsa  dcu  dcd  dlog  dex"
        echo "System:      df  free  ports  myip  cpucap"
        echo "Tools:       extract  backup  qfind  serve  duh"
      }

      # =======================================================================
      # WELCOME SCREEN - Enhanced
      # =======================================================================

      _show_welcome() {
        local RST=$'\033[0m'
        local BLD=$'\033[1m'
        local CYN=$'\033[1;36m'
        local BLU=$'\033[1;34m'
        local GRN=$'\033[1;32m'
        local YLW=$'\033[1;33m'
        local MAG=$'\033[1;35m'
        local RED=$'\033[1;31m'
        local WHT=$'\033[1;37m'
        local GRY=$'\033[0;90m'

        # System info (use command to bypass aliases)
        local user=$(whoami)
        local host=$(hostname -s)
        local hostname_full=$(hostname)
        local os="NixOS"
        local kernel=$(uname -r)
        local kernel_short=$(uname -r | cut -d'-' -f1)
        local arch=$(uname -m)
        local shell="Zsh $ZSH_VERSION"
        local term="''${TERM:-unknown}"
        local de="''${XDG_CURRENT_DESKTOP:-unknown}"

        # Uptime
        local uptime_secs=$(command cat /proc/uptime | cut -d. -f1)
        local uptime_days=$((uptime_secs / 86400))
        local uptime_hours=$(((uptime_secs % 86400) / 3600))
        local uptime_mins=$(((uptime_secs % 3600) / 60))
        local uptime="''${uptime_days}d ''${uptime_hours}h ''${uptime_mins}m"
        local load=$(command cat /proc/loadavg | awk '{print $1, $2, $3}')

        # Memory
        local mem_used=$(command free -h | awk '/Mem:/ {print $3}')
        local mem_total=$(command free -h | awk '/Mem:/ {print $2}')
        local mem_perc=$(command free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')

        # Disk
        local disk_used=$(command df -h /nix | awk 'NR==2 {print $3}')
        local disk_total=$(command df -h /nix | awk 'NR==2 {print $2}')
        local disk_perc=$(command df /nix | awk 'NR==2 {gsub(/%/,""); print $5}')

        # CPU
        local cpu_model=$(command grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //' | sed 's/(R)//g' | sed 's/(TM)//g' | cut -c1-30)
        local cpu_cores=$(nproc)
        local cpu_freq=$(command cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        cpu_freq=$((cpu_freq/1000))

        # GPU
        local gpu=$(lspci 2>/dev/null | grep -i vga | sed 's/.*controller: //' | sed 's/ (rev .*//' | cut -c1-40)

        # Network
        local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

        # Environment
        local datetime=$(date '+%d-%m-%Y %H:%M:%S')
        local curpath=$(pwd | sed "s|$HOME|~|" | cut -c1-16)
        local pkgs=$(command ls /nix/store 2>/dev/null | wc -l)
        local procs=$(command ls -d /proc/[0-9]* 2>/dev/null | wc -l)
        local python_ver=$(python3 --version 2>/dev/null | awk '{print $2}')
        local node_ver=$(node --version 2>/dev/null | tr -d 'v')
        local git_ver=$(git --version 2>/dev/null | awk '{print $3}')

        # ASCII Art Banner
        echo ""
        echo "$CYN    ███████╗███████╗██╗  ██╗$RST"
        echo "$CYN    ╚══███╔╝██╔════╝██║  ██║$RST"
        echo "$CYN      ███╔╝ ███████╗███████║$RST"
        echo "$CYN     ███╔╝  ╚════██║██╔══██║$RST"
        echo "$CYN    ███████╗███████║██║  ██║$RST"
        echo "$CYN    ╚══════╝╚══════╝╚═╝  ╚═╝$RST"
        echo ""

        # Header bar
        echo "$BLU  ╭────────────────────────────────────────────────────────────────────╮$RST"
        printf "  │ $WHT$BLD%s$RST$GRY@$RST$GRN%s $RST$GRY│$RST $CYN%s $RST$GRY│$RST ''${YLW}%-16s$RST$BLU│$RST\n" "$user" "$host" "$datetime" "$curpath"
        echo "$BLU  ╰────────────────────────────────────────────────────────────────────╯$RST"
        echo ""

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 1: SYSTEM LEVEL - Hardware | System | Network (wider cards ~35 chars each = 105+ total)
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        echo "$MAG  ┌─ HARDWARE ─────────────────────┐$RST $YLW┌─ SYSTEM ───────────────────────┐$RST $BLU┌─ NETWORK ──────────────────────┐$RST"
        printf "  │ CPU   %-25s│ │ OS     %-24s│ │ IP    %-25s│\n" "$cpu_model" "$os $kernel_short ($arch)" "$ip"
        printf "  │ Cores %-25s│ │ Host   %-24s│ │ Load  %-25s│\n" "$cpu_cores cores @ $cpu_freq MHz" "$hostname_full" "$load"
        printf "  │ GPU   %-25s│ │ Kernel %-24s│ │ Up    %-25s│\n" "${gpu:0:25}" "$kernel" "$uptime"
        printf "  │ RAM   %-25s│ │ DE     %-24s│ │ Pkgs  %-25s│\n" "$mem_used / $mem_total ($mem_perc%)" "$de ($term)" "$pkgs (nix-store)"
        printf "  │ Disk  %-25s│ │ Shell  %-24s│ │ Procs %-25s│\n" "$disk_used / $disk_total ($disk_perc%)" "$shell" "$procs running"
        echo "$MAG  └────────────────────────────────┘$RST $YLW└────────────────────────────────┘$RST $BLU└────────────────────────────────┘$RST"
        echo ""

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 2: LANGUAGES & COMPILERS
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        local rust_v=$(rustc --version 2>/dev/null | awk '{print $2}' || echo "-")
        local go_v=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || echo "-")
        local py_v=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "-")
        local gcc_v=$(gcc --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "-")
        local java_v=$(java --version 2>/dev/null | head -1 | awk '{print $2}' || echo "-")
        local ruby_v=$(ruby --version 2>/dev/null | awk '{print $2}' || echo "-")
        local R_v=$(R --version 2>/dev/null | head -1 | awk '{print $3}' || echo "-")

        echo "$GRN  ┌─ LANGUAGES ────────────────────┐$RST $CYN┌─ CLI CORE ─────────────────────┐$RST $WHT┌─ CONTAINERS & CLOUD ───────────┐$RST"
        printf "  │ rust %-9s go %-12s│ │ eza bat fd rg fzf zoxide     │ │ podman buildah skopeo dive    │\n" "$rust_v" "$go_v"
        printf "  │ python %-7s gcc %-10s│ │ yazi btop ncdu duf tree htop │ │ kubectl helm k9s kubectx stern│\n" "$py_v" "$gcc_v"
        printf "  │ node %-9s java %-9s│ │ jq yq gh rsync rclone curl   │ │ ansible sops age prometheus   │\n" "$node_ver" "$java_v"
        printf "  │ ruby %-9s R %-12s│ │ wget xclip wl-clipboard neofet│ │ aws gcloud azure-cli oci-cli  │\n" "$ruby_v" "$R_v"
        echo "$GRN  └────────────────────────────────┘$RST $CYN└────────────────────────────────┘$RST $WHT└────────────────────────────────┘$RST"
        echo ""

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 3: DEV TOOLS - Build | Network | Data
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        echo "$RED  ┌─ BUILD & DEBUG ────────────────┐$RST $BLU┌─ NETWORK & SECURITY ───────────┐$RST $MAG┌─ DATA & SCIENCE ───────────────┐$RST"
        printf "  │ cmake ninja make meson autoconf│ │ nmap mtr tcpdump iftop nethogs│ │ sqlite postgres mysql redis   │\n"
        printf "  │ gdb lldb valgrind strace ltrace│ │ wireshark tshark netcat httpie│ │ pgcli mycli litecli           │\n"
        printf "  │ clang-tools cppcheck shellcheck│ │ tor wireguard openvpn dnscrypt│ │ jupyter pandas numpy scipy    │\n"
        printf "  │ shfmt delta diff-so-fancy act  │ │ gnupg pass gopass openssl age │ │ torch scikit-learn matplotlib │\n"
        printf "  │ pandoc doxygen graphviz just   │ │ ssh-audit lynis binwalk hexyl │ │ R ggplot2 dplyr polars dask   │\n"
        echo "$RED  └────────────────────────────────┘$RST $BLU└────────────────────────────────┘$RST $MAG└────────────────────────────────┘$RST"
        echo ""

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 4: SHELL HELP - Aliases | Functions | FZF Keys
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        echo "$CYN  ┌─ ALIASES ──────────────────────┐$RST $YLW┌─ FUNCTIONS ────────────────────┐$RST $GRN┌─ FZF KEYBINDINGS ──────────────┐$RST"
        printf "  │ ll la lt lh tree  (eza)       │ │ mkcd <dir>    mkdir and cd    │ │ Ctrl+R   Search command history│\n"
        printf "  │ gs ga gc gp gl gd glog (git)  │ │ extract <f>   unpack any arch │ │ Ctrl+T   Search files (insert) │\n"
        printf "  │ .. ... .... z mkcd  (nav)     │ │ backup <f>    timestamped copy│ │ Alt+C    cd into directory     │\n"
        printf "  │ df du free ports myip (sys)   │ │ qfind <name>  quick find      │ │ Ctrl+/   Toggle preview window │\n"
        printf "  │ py pip docker dps dcu (dev)   │ │ gcam gpsh serve cpucap        │ │ Ctrl+A/Y Select all / Yank     │\n"
        echo "$CYN  └────────────────────────────────┘$RST $YLW└────────────────────────────────┘$RST $GRN└────────────────────────────────┘$RST"
        echo ""

        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        # ROW 5: GUI APPS - Office | Media | Files
        # ═══════════════════════════════════════════════════════════════════════════════════════════════════════
        echo "$BLU  ┌─ OFFICE & PRODUCTIVITY ────────┐$RST $MAG┌─ MEDIA & GRAPHICS ─────────────┐$RST $GRN┌─ FILES & UTILITIES ────────────┐$RST"
        printf "  │ libreoffice (office suite)    │ │ gimp krita inkscape (graphics)│ │ dolphin ranger mc yazi (files)│\n"
        printf "  │ obsidian zettlr joplin (notes)│ │ kdenlive obs-studio (video)   │ │ okular zathura (pdf viewers)  │\n"
        printf "  │ okular zathura (pdf readers)  │ │ vlc mpv audacity (audio/video)│ │ gwenview feh imv (images)     │\n"
        printf "  │ taskwarrior vit calcurse (org)│ │ ffmpeg imagemagick sox (cli)  │ │ flameshot peek maim (capture) │\n"
        printf "  │ pandoc mdcat glow (markdown)  │ │ digikam drawio gpick (utils)  │ │ p7zip unrar zip ark (archive) │\n"
        echo "$BLU  └────────────────────────────────┘$RST $MAG└────────────────────────────────┘$RST $GRN└────────────────────────────────┘$RST"
        echo ""
      }

      # Show welcome on interactive shell
      [[ -o interactive ]] && _show_welcome

      # Local overrides
      [[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
    '';
  };
}
