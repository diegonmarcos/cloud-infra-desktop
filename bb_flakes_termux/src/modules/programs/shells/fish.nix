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

    shellAliases = lib.mkDefault {
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
      top-batch = "echo '=== CPU/MEM ===' && top -bn1 | head -5 && echo '\\n=== TOP PROCS (CPU) ===' && top -bn1 -o %CPU | tail -n+8 | head -15 && echo '\\n=== DISK ===' && df -h / /home /boot 2>/dev/null && echo '\\n=== DOCKER ===' && docker stats --no-stream --format 'table {{.Name}}\\t{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.MemPerc}}' 2>/dev/null || true";

      # Misc
      c = "clear";
      cls = "clear";
      h = "history";
      path = "echo $PATH | tr ':' '\\n'";
      reload = "source ~/.config/fish/config.fish";

      # Session (Plasma 6)
      logout = "killall -9 -u $USER; qdbus org.kde.Shutdown /Shutdown logout";
      reboot = "qdbus org.kde.Shutdown /Shutdown logoutAndReboot";
      poweroff = "qdbus org.kde.Shutdown /Shutdown logoutAndShutdown";

      # Browser dev
      chrome_no_CORS = "chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors";

      # Custom tools
      dtk = "bash ~/git/tools/dtk.sh";
      gdrive = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh";

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
      serve = builtins.readFile ./fish/functions/serve.fish;
      duh = builtins.readFile ./fish/functions/duh.fish;
      localip = builtins.readFile ./fish/functions/localip.fish;
      hg = builtins.readFile ./fish/functions/hg.fish;
      myhelp = builtins.readFile ./fish/functions/myhelp.fish;
      "__fzf_search_commands" = builtins.readFile ./fish/functions/__fzf_search_commands.fish;
    };

    interactiveShellInit = builtins.readFile ./fish/interactiveShellInit.fish;
  };
}
