# Fish shell configuration
{ config, pkgs, lib, ... }:

{
  programs.fish = {
    enable = true;

    shellAbbrs = {
      # Git
      gs = "git status -sb";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git log --oneline -20";
      gd = "git diff";
      gco = "git checkout";

      # Podman
      dps = "podman ps";
      dpsa = "podman ps -a";
    };

    shellAliases = {
      # Modern CLI
      ls = "eza --color=auto --icons";
      ll = "eza -alF --icons";
      la = "eza -A --icons";
      lt = "eza --tree --level=2 --icons";
      cat = "bat --paging=never";
      grep = "rg";
      find = "fd";
      docker = "podman";

      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";

      # Misc
      cls = "clear";
      path = "echo $PATH | tr ':' '\\n'";
      myip = "curl -s ifconfig.me";
    };

    functions = {
      mkcd = "mkdir -p $argv[1]; and cd $argv[1]";

      fish_greeting = "";

      extract = ''
        if test -f $argv[1]
          switch $argv[1]
            case '*.tar.bz2'
              tar xjf $argv[1]
            case '*.tar.gz'
              tar xzf $argv[1]
            case '*.tar.xz'
              tar xJf $argv[1]
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
            case '*'
              echo "'$argv[1]' cannot be extracted"
          end
        end
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

      # Vi mode
      fish_vi_key_bindings

      # SSH agent
      if test -z "$SSH_AUTH_SOCK"
        eval (ssh-agent -c) &>/dev/null
        ssh-add ~/.ssh/id_rsa 2>/dev/null
      end

      # Local overrides
      if test -f ~/.config/fish/config.local.fish
        source ~/.config/fish/config.local.fish
      end
    '';
  };
}
