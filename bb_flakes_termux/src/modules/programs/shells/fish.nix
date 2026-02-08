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
      fish_greeting = ''
        set_color cyan
        echo "=================================="
        echo "   Nix-on-Droid Terminal"
        echo "=================================="
        set_color normal
        echo ""
        set_color yellow
        echo "Commands:"
        set_color normal
        set_color green; echo -n "  c       "; set_color normal; echo "Launch Claude Code"
        set_color green; echo -n "  cc      "; set_color normal; echo "Launch Claude Code (alt)"
        set_color green; echo -n "  code    "; set_color normal; echo "VS Code Server (local/lan/stop)"
        set_color cyan
        echo ""
        echo "Git:"
        set_color normal
        set_color yellow; echo -n "  gacp    "; set_color normal; echo "git add . && commit && push"
        set_color yellow; echo -n "  gcl     "; set_color normal; echo "git clone <url>"
        set_color cyan
        echo ""
        echo "System:"
        set_color normal
        set_color magenta; echo -n "  up      "; set_color normal; echo "Rebuild Nix config"
        set_color magenta; echo -n "  conf    "; set_color normal; echo "Edit flake.nix"
        set_color magenta; echo -n "  sync    "; set_color normal; echo "File server & sync (WebDAV:8082 SFTP:2022 HTTP:8083)"
        set_color cyan
        echo ""
        echo "Search (fzf):"
        set_color normal
        set_color blue; echo -n "  Ctrl+T  "; set_color normal; echo "Find file"
        set_color blue; echo -n "  Ctrl+R  "; set_color normal; echo "Search history"
        set_color blue; echo -n "  Alt+C   "; set_color normal; echo "Cd to folder"
        set_color cyan
        echo ""
        echo "Navigation:"
        set_color normal
        set_color blue; echo -n "  ll      "; set_color normal; echo "List files (detailed)"
        set_color blue; echo -n "  ..      "; set_color normal; echo "Go up one directory"
        set_color cyan
        echo "=================================="
        set_color normal
      '';

      __nix_guard_msg = ''
        set_color --bold red
        echo "STOP: packages are managed via nix flake."
        set_color normal
        echo "  Add to: ~/git/unix/bb_flakes_termux/src/modules/packages.nix"
        echo "  Then:   home-manager switch --flake ~/git/unix/bb_flakes_termux/src#nix-on-droid"
        echo "  Temp:   nix-shell -p <package>"
        set_color brblack
        echo "Blocked: $argv"
        set_color normal
      '';

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

      serve = "python3 -m http.server $argv[1]; or python3 -m http.server 8000";

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
