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
      dps = "docker ps";
      dpsa = "docker ps -a";
      dcu = "docker compose up";
      dcd = "docker compose down";
    };

    # NO mkDefault: flake.nix also defines shellAliases (sharedAliases) at
    # normal priority, and for attrsOf options a lower-priority definition is
    # DISCARDED WHOLE, not merged — every alias below was dead code until
    # 2026-08-08. Same priority => key-wise merge.
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
      # docker is real docker — no alias needed

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
      du = "ncdu";
      free = "free -h";
      ports = "ss -tulanp";
      myip = "curl -s ifconfig.me";
      # (top-batch removed 2026-08-08 — df /home /boot + docker stats are
      # desktop-only; use `top` / `duh` here.)

      # Misc
      c = "clear";
      cls = "clear";
      h = "history";
      path = "echo $PATH | tr ':' '\\n'";
      reload = "source ~/.config/fish/config.fish";

      # (Plasma session, chromium, and /home/diego-path aliases removed
      # 2026-08-08 — qdbus/chromium don't exist on Android, and `logout`
      # even ran killall -9 -u $USER before failing. dtk comes from
      # flake.nix sharedAliases.)

      # AI CLIs — see interactiveShellInit for ai-cli function

      # Welcome screen
      welcome = "fish_greeting";
    };

    functions = {
      up = builtins.readFile ./fish/functions/up.fish;
      "ai-cli" = builtins.readFile ./fish/functions/ai-cli.fish;
      "cloud-ai-cli" = builtins.readFile ./fish/functions/cloud-ai-cli.fish;
      fish_greeting = builtins.readFile ./fish/functions/fish_greeting.fish;
      hhelp = builtins.readFile ./fish/functions/hhelp.fish;
      mkcd = builtins.readFile ./fish/functions/mkcd.fish;
      mkd = builtins.readFile ./fish/functions/mkd.fish;
      extract = builtins.readFile ./fish/functions/extract.fish;
      qfind = builtins.readFile ./fish/functions/qfind.fish;
      backup = builtins.readFile ./fish/functions/backup.fish;
      git_current_branch = builtins.readFile ./fish/functions/git_current_branch.fish;
      gcam = builtins.readFile ./fish/functions/gcam.fish;
      gpsh = builtins.readFile ./fish/functions/gpsh.fish;
      gacp = builtins.readFile ./fish/functions/gacp.fish;
      cpucap = builtins.readFile ./fish/functions/cpucap.fish;
      # serve — real binary; the old serve.fish called http-dev, which no
      # module ever installed (2026-08-08 audit).
      serve = "httpd-web-server-json-md-eruda start $argv";
      duh = builtins.readFile ./fish/functions/duh.fish;
      localip = builtins.readFile ./fish/functions/localip.fish;
      hg = builtins.readFile ./fish/functions/hg.fish;
      myhelp = builtins.readFile ./fish/functions/myhelp.fish;
      "__fzf_search_commands" = builtins.readFile ./fish/functions/__fzf_search_commands.fish;
    };

    interactiveShellInit = builtins.readFile ./fish/interactiveShellInit.fish;
  };
}
