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

      # Nix package guard
      __nix_guard_msg() {
        echo -e "\033[1;31mSTOP: packages are managed via nix flake.\033[0m"
        echo "  Add to: ~/git/unix/bb_flakes_termux/src/modules/packages.nix"
        echo "  Then:   home-manager switch --flake ~/git/unix/bb_flakes_termux/src#nix-on-droid"
        echo "  Temp:   nix-shell -p <package>"
        echo -e "\033[0;90mBlocked: $1\033[0m"
      }

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
