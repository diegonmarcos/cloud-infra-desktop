# Bash shell configuration
{ config, pkgs, lib, ... }:

{
  programs.bash = {
    enable = true;
    enableCompletion = true;

    historySize = 10000;
    historyFileSize = 20000;
    historyControl = [ "ignoreboth" "erasedups" ];

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

      # Git shortcuts
      gs = "git status -sb";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git log --oneline -20";
      gd = "git diff";
      gco = "git checkout";

      # Podman/Docker
      docker = "podman";
      dc = "podman-compose";
      dps = "podman ps";
      dpsa = "podman ps -a";

      # Misc
      cls = "clear";
      path = "echo $PATH | tr ':' '\\n'";
      ports = "ss -tulanp";
      myip = "curl -s ifconfig.me";
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

      # SSH agent
      if [[ -z "$SSH_AUTH_SOCK" ]]; then
        eval "$(ssh-agent -s)" &>/dev/null
        ssh-add ~/.ssh/id_rsa 2>/dev/null || true
      fi

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

      # Quick HTTP server
      serve() {
        local port="''${1:-8000}"
        python3 -m http.server "$port"
      }

      # Find and replace in files
      replace() {
        if [[ $# -lt 3 ]]; then
          echo "Usage: replace <find> <replace> <files...>"
          return 1
        fi
        local find="$1" replace="$2"
        shift 2
        sed -i "s/$find/$replace/g" "$@"
      }

      # Local overrides
      [[ -f ~/.bashrc.local ]] && source ~/.bashrc.local
    '';
  };
}
