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
            set_color --bold cyan
            echo ""
            echo "    ╔═══╗ ╔══╗        ╔═══╗ ╦    ╔══╗"
            echo "    ╠═══╣  ║   ═══    ║    ║     ║  "
            echo "    ║   ║ ╚══╝        ╚═══╝ ╩══╝ ╩  "
            set_color normal
            set_color --bold white; echo "    Unified AI Agent Launcher"; set_color normal
            set_color --dim; echo "    goose v"(goose --version 2>/dev/null | string match -r '[\d.]+'; or echo "?")" · block/goose · MCP-native"; set_color normal
            echo ""
            set_color --bold yellow; echo "  ── Cloud Models (Anthropic API) ─────────────────────────────────────"; set_color normal
            echo ""
            set_color green; echo -n "    (default)  "; set_color --bold white; echo -n "Haiku  4.5  "; set_color normal; echo -n " 200K ctx  "; set_color --dim; echo "\$0.80/\$4.00   batch \$0.40/\$2.00"; set_color normal
            set_color green; echo -n "    sonnet     "; set_color --bold white; echo -n "Sonnet 4.6  "; set_color normal; echo -n " 200K ctx  "; set_color --dim; echo "\$3.00/\$15.00  batch \$1.50/\$7.50"; set_color normal
            set_color green; echo -n "    opus       "; set_color --bold white; echo -n "Opus   4.6  "; set_color normal; echo -n "   1M ctx  "; set_color --dim; echo "\$15.00/\$75.00 batch \$7.50/\$37.50"; set_color normal
            echo ""
            set_color --bold yellow; echo "  ── Local Models (Ollama · oci-apps ARM) ────────────────────────────"; set_color normal
            echo ""
            set_color cyan; echo -n "    local      "; set_color --bold white; echo -n "Qwen   1.5B "; set_color normal; echo -n "   4K ctx  "; set_color --dim; echo "free · Q4_K_M · ~12s/msg"; set_color normal
            echo ""
            set_color --bold yellow; echo "  ── MCP Extensions ───────────────────────────────────────────────────"; set_color normal
            echo ""
            set_color --dim
            echo "    cloud-services         Mattermost, Mail, Dagu, GHA, Ollama, ntfy"
            echo "    cloud-infra            SSH, Docker, health checks, builds, deploys"
            echo "    cloud-cgc-mcp          Infra knowledge graph, octocode semantic search"
            echo "    google-workspace       Gmail, Calendar, Drive, Docs, Sheets"
            echo "    diego-personal-data    Vault, identity, finance (read-only)"
            set_color normal
            echo "    Enable: goose configure → Extensions"
            echo ""
            set_color --bold yellow; echo "  ── Usage ────────────────────────────────────────────────────────────"; set_color normal
            echo ""
            echo "    ai-cli                 Launch with Haiku 4.5 (default)"
            echo "    ai-cli sonnet          Launch with Sonnet 4.6"
            echo "    ai-cli opus            Launch with Opus 4.6"
            echo "    ai-cli local           Launch with local Qwen (free)"
            echo "    ai-cli -h              This help"
            echo ""
            set_color --dim; echo "    Config: ~/.config/goose/config.yaml"; set_color normal
            echo ""
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
