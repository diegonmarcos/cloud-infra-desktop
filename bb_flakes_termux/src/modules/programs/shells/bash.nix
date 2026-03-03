# Bash shell configuration - Termux / nix-on-droid
{ config, pkgs, lib, ... }:

{
  programs.bash = {
    enable = true;
    enableCompletion = true;

    historySize = 10000;
    historyFileSize = 20000;
    historyControl = [ "ignoreboth" "erasedups" ];
    historyIgnore = [ "ls" "ll" "la" "cd" "pwd" "exit" "clear" "c" ];

    shellOptions = [
      "histappend"
      "checkwinsize"
      "globstar"
      "cdspell"
      "autocd"
    ];

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

      # Safety
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";

      # Python
      py = "python3";
      python = "python3";

      # Git shortcuts
      gs = "git status -sb";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gp = "git push";
      gl = "git log --oneline --graph --decorate -20";
      gd = "git diff";
      gds = "git diff --staged";
      gco = "git checkout";
      gpl = "git pull";

      # System
      df = "duf";
      du = "ncdu";
      myip = "curl -s ifconfig.me";

      # Misc
      c = "clear";
      h = "history";
      hg = "history | grep";
      path = "echo $PATH | tr ':' '\\n'";
      reload = "source ~/.bashrc";
    };

    initExtra = ''
      # Starship prompt
      if command -v starship &>/dev/null; then
        eval "$(starship init bash)"
      fi

      # Zoxide (smart cd)
      if command -v zoxide &>/dev/null; then
        eval "$(zoxide init bash)"
      fi

      # FZF integration
      if command -v fzf &>/dev/null; then
        eval "$(fzf --bash)"
      fi

      # Nix declarative environment guard
      __nix_guard_msg() {
        echo ""
        echo -e "\033[1;31m  ╔══════════════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;31m  ║  READ CLAUDE.MD AND MEMORY.MD!                              ║\033[0m"
        echo -e "\033[1;31m  ║  THIS IS A FULL DECLARATIVE ENVIRONMENT, NIX-FLAKES WAY!!!  ║\033[0m"
        echo -e "\033[1;31m  ╚══════════════════════════════════════════════════════════════╝\033[0m"
        echo ""
        echo -e "\033[0;33m  Packages → ~/git/unix/bb_flakes_termux/src/modules/packages.nix\033[0m"
        echo -e "\033[0;33m  JS deps  → project/package.json → build.sh deps\033[0m"
        echo -e "\033[0;33m  Build    → build.sh (ALWAYS)\033[0m"
        echo -e "\033[0;33m  Temp pkg → nix-shell -p <package>\033[0m"
        echo ""
        echo -e "\033[0;90m  Blocked: $1\033[0m"
        return 1
      }
      npm()      { __nix_guard_msg "npm $*"; }
      npx()      { __nix_guard_msg "npx $*"; }
      apt()      { __nix_guard_msg "apt $*"; }
      apt-get()  { __nix_guard_msg "apt-get $*"; }
      pkg()      { __nix_guard_msg "pkg $*"; }
      pip()      { __nix_guard_msg "pip $*"; }
      pip3()     { __nix_guard_msg "pip3 $*"; }
      nix-env()  { __nix_guard_msg "nix-env $*"; }
      yarn()     { __nix_guard_msg "yarn $*"; }
      pnpm()     { __nix_guard_msg "pnpm $*"; }

      # Functions
      mkcd() { mkdir -p "$1" && cd "$1"; }

      extract() {
        if [[ -f "$1" ]]; then
          case "$1" in
            *.tar.bz2) tar xjf "$1" ;;
            *.tar.gz)  tar xzf "$1" ;;
            *.tar.xz)  tar xJf "$1" ;;
            *.bz2)     bunzip2 "$1" ;;
            *.gz)      gunzip "$1" ;;
            *.tar)     tar xf "$1" ;;
            *.zip)     unzip "$1" ;;
            *.7z)      7z x "$1" ;;
            *)         echo "'$1' cannot be extracted" ;;
          esac
        fi
      }

      backup() {
        if [ -f "$1" ]; then
          cp "$1" "$1.backup.$(date +%Y%m%d_%H%M%S)"
          echo "Backup: $1.backup.$(date +%Y%m%d_%H%M%S)"
        fi
      }

      gcam() { git add --all && git commit -m "$1"; }

      serve() { python3 -m http.server "''${1:-8000}"; }

      # Local overrides
      [[ -f ~/.bashrc.local ]] && source ~/.bashrc.local
    '';
  };
}
