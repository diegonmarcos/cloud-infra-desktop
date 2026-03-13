# Fish shell configuration - Termux / nix-on-droid
{ config, pkgs, lib, ... }:

{
  programs.fish = {
    enable = true;

    shellAbbrs = {
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
    };

    shellAliases = {
      ls = "eza --color=auto --icons";
      ll = "eza -alF --icons";
      la = "eza -A --icons";
      l = "eza -CF --icons";
      lh = "eza -lh --icons";
      lt = "eza --tree --level=2 --icons";
      cat = "bat --paging=never";
      grep = "rg";
      find = "fd";

      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";

      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";

      py = "python3";
      python = "python3";

      df = "duf";
      du = "ncdu";
      myip = "curl -s ifconfig.me";

      c = "clear";
      h = "history";
      path = "echo $PATH | tr ':' '\\n'";
      reload = "source ~/.config/fish/config.fish";
    };

    functions = {

      mkcd = "mkdir -p $argv[1]; and cd $argv[1]";

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
            case '*'
              echo "'$argv[1]' cannot be extracted"
          end
        end
      '';

      backup = ''
        if test -f $argv[1]
          set -l timestamp (date +%Y%m%d_%H%M%S)
          cp $argv[1] "$argv[1].backup.$timestamp"
          echo "Backup: $argv[1].backup.$timestamp"
        end
      '';

      gcam = "git add --all; and git commit -m $argv[1]";

      serve = "http-dev start $argv";

      hg = "history | grep $argv";
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

      # http-dev auto-start is handled in flake.nix interactiveShellInit

      # Cargo
      if test -d $HOME/.cargo/bin
        fish_add_path $HOME/.cargo/bin
      end

      # Local overrides
      if test -f ~/.config/fish/config.local.fish
        source ~/.config/fish/config.local.fish
      end
    '';
  };
}
