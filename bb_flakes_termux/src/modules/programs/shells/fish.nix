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

      # AI CLIs — ai-cli function in functions block
      cloud-ai-cli = "ai-cli";  # back-compat alias
    };

    functions = {
      ai-cli = ''
        switch "$argv[1]"
          case -h --help help models
            echo "ai-cli — Unified AI Agent launcher (Goose + MCP)"
            echo ""
            echo "Usage: ai-cli [model] [goose args...]"
            echo ""
            echo "Models:"
            echo "  (default)  Haiku 4.5 · 200K ctx · \$0.80/\$4 in|out (batch: \$0.40/\$2) · ~2s"
            echo "  sonnet     Sonnet 4.6 · 200K ctx · \$3/\$15 in|out (batch: \$1.50/\$7.50) · ~3s"
            echo "  opus       Opus 4.6 · 200K ctx · \$15/\$75 in|out (batch: \$7.50/\$37.50) · ~5s"
            echo "  local      qwen2.5 1.5B Q4 · 4K ctx · Ollama oci-apps · free · ~12s"
            echo ""
            echo "Examples:"
            echo "  ai-cli              # Haiku (default)"
            echo "  ai-cli sonnet       # Sonnet"
            echo "  ai-cli local        # Local qwen on Ollama"
          case sonnet
            GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-sonnet-4-6 goose $argv[2..]
          case opus
            GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-opus-4-6 goose $argv[2..]
          case local qwen
            GOOSE_PROVIDER=ollama GOOSE_MODEL=qwen2.5-4k goose $argv[2..]
          case ""
            GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-haiku-4-5-20251001 goose
          case haiku
            GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-haiku-4-5-20251001 goose $argv[2..]
          case "*"
            GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-haiku-4-5-20251001 goose $argv
        end
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
