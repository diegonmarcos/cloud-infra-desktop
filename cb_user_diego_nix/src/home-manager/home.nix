{ config, pkgs, ... }:

{
  home.username = "diego";
  home.homeDirectory = "/home/diego";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # PACKAGES TO INSTALL
  # ═══════════════════════════════════════════════════════════════════════════

  home.packages = with pkgs; [
    # CLI Tools
    btop
    ripgrep
    fd
    fzf
    jq
    tree
    unzip
    wget
    curl

    # Development
    git
    gh  # GitHub CLI

    # Shell
    fish
    starship
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # FISH SHELL
  # ═══════════════════════════════════════════════════════════════════════════

  programs.fish = {
    enable = true;

    shellAliases = {
      # Python
      py = "python3";
      python = "python3";
      pip = "pip3";

      # Directory Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      "....." = "cd ../../../..";

      # List Directory
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";
      lh = "ls -lh";
      lt = "ls -ltr";

      # Git
      gs = "git status";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gp = "git push";
      gl = "git log --oneline --graph --decorate";
      gla = "git log --oneline --graph --decorate --all";
      gd = "git diff";
      gds = "git diff --staged";
      gco = "git checkout";
      gb = "git branch";
      gba = "git branch -a";
      gpl = "git pull";
      gcl = "git clone";
      gst = "git stash";
      gstp = "git stash pop";
      push = "git add . && git commit -m 'update' && git push";

      # Grep with Colors
      grep = "grep --color=auto";
      fgrep = "fgrep --color=auto";
      egrep = "egrep --color=auto";

      # Safety Aliases
      cp = "cp -i";
      mv = "mv -i";
      rm = "rm -i";

      # System Information
      df = "df -h";
      du = "du -h";
      free = "free -h";

      # Networking
      ports = "netstat -tulanp";
      myip = "curl -s ifconfig.me";
      ping = "ping -c 5";

      # Misc
      c = "clear";
      h = "history";
      reload = "source ~/.config/fish/config.fish";

      # Config Editing
      editfish = "$EDITOR ~/.config/fish/config.fish";
      sourcefish = "source ~/.config/fish/config.fish";

      # Development
      serve = "python3 -m http.server";
      jn = "jupyter notebook";
      dcu = "docker-compose up";
      dcd = "docker-compose down";
      dps = "docker ps";
      dpsa = "docker ps -a";

      # Custom Tools
      mem_recover = "/home/diego/Documents/Git/mylibs/mytools/0_unix/kill_halt.sh";
      mem_usage = "/home/diego/Documents/Git/mylibs/mytools/0_unix/mem_usage.sh";
      gdrive = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh";
      gdrive_reset = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh b2";
      gdrive_mount = "bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh b1";
      gdrive_umount = "fusermount -u /home/diego/Documents/Gdrive";

      # Poetry
      ppy = "poetry run python3";
    };

    functions = {
      # Create directory and cd into it
      mkcd = "mkdir -p $argv[1]; and cd $argv[1]";
      mkd = "mkdir -p $argv; and cd $argv[-1]";

      # Extract any archive
      extract = ''
        if test -f $argv[1]
          switch $argv[1]
            case '*.tar.bz2'
              tar xjf $argv[1]
            case '*.tar.gz'
              tar xzf $argv[1]
            case '*.bz2'
              bunzip2 $argv[1]
            case '*.rar'
              unrar x $argv[1]
            case '*.gz'
              gunzip $argv[1]
            case '*.tar'
              tar xf $argv[1]
            case '*.tbz2'
              tar xjf $argv[1]
            case '*.tgz'
              tar xzf $argv[1]
            case '*.zip'
              unzip $argv[1]
            case '*.Z'
              uncompress $argv[1]
            case '*.7z'
              7z x $argv[1]
            case '*.deb'
              ar x $argv[1]
            case '*.tar.xz'
              tar xf $argv[1]
            case '*.tar.zst'
              unzstd $argv[1]
            case '*'
              echo "'$argv[1]' cannot be extracted via extract()"
          end
        else
          echo "'$argv[1]' is not a valid file"
        end
      '';

      # Quick find
      qfind = "find . -name \"*$argv[1]*\"";

      # Backup file with timestamp
      backup = ''
        if test -f $argv[1]
          set timestamp (date +%Y%m%d_%H%M%S)
          cp $argv[1] "$argv[1].backup.$timestamp"
          echo "Backup created: $argv[1].backup.$timestamp"
        else
          echo "File not found: $argv[1]"
        end
      '';

      # Get current git branch
      git_current_branch = "git branch 2>/dev/null | sed -n '/\\* /s///p'";

      # Quick git commit with message
      gcam = "git add --all; and git commit -m $argv[1]";

      # Quick git push to current branch
      gpsh = "git push origin (git_current_branch)";

      # Print path with newlines
      path = "echo $PATH | tr ' ' '\\n'";

      # System info functions
      get_system_info = ''
        set os_name (uname -s)
        set kernel_version (uname -r)
        set current_hostname (hostname)
        set uptime (uptime | awk '{print $3, $4}' | sed 's/,//')
        set cpu_model (lscpu | grep "Model name:" | awk '{print $3,$4,$5,$6,$7,$8}')
        set memory_usage (free -h | awk '/Mem:/ {printf "%.1f GB / %.1f GB", $3/1024/1024, $2/1024/1024}')
        echo -e "\n1.System Information:"
        echo -e "------------------"
        echo -e "OS:\t\t$os_name"
        echo -e "Kernel:\t\t$kernel_version"
        echo -e "Hostname:\t$current_hostname"
        echo -e "Uptime:\t\t$uptime"
        echo -e "CPU:\t\t$cpu_model"
        echo -e "Memory:\t\t$memory_usage"
      '';

      get_network_info = ''
        set ip_address (ip route get 1.1.1.1 | awk '{print $7}')
        set gateway (ip route | grep default | awk '{print $3}')
        echo -e "\n2.Network Information:"
        echo -e "-------------------"
        echo -e "IP Address:\t$ip_address"
        echo -e "Gateway:\t$gateway"
      '';

      get_disk_usage = ''
        set disk_usage (df -h / | awk 'NR==2 {printf "%s / %s (%.1f%%)", $3, $2, $5}')
        echo -e "\n3.Disk Usage:"
        echo -e "-----------"
        echo -e "Root:\t\t$disk_usage"
      '';

      # Claude Code usage stats
      ccusage-models = ''
        ccusage session --json -b | jq -r '.sessions[0].modelBreakdowns[] | [.modelName, (.inputTokens | tostring), (.outputTokens | tostring), ((.inputTokens + .outputTokens) | tostring), ("$" + (.cost | round | tostring))] | @csv' | sed 's/"//g' | awk -F',' 'BEGIN {printf "%-30s %15s %15s %15s %15s\n", "MODEL", "INPUT", "OUTPUT", "TOTAL", "COST"; print "---------------------------------------------------------------"} {printf "%-30s %15s %15s %15s %15s\n", $1, sprintf("%\047d", $2), sprintf("%\047d", $3), sprintf("%\047d", $4), $5}'
      '';
    };

    interactiveShellInit = ''
      # Add local bin to path
      fish_add_path /home/diego/.local/bin

      # Set variables
      set -g path_to_my_git "/home/diego/Documents/Git/"
      set -gx DBX_CONTAINER_MANAGER docker

      # Rclone mount check on login
      if not mount | grep -q "/home/diego/Documents/Gdrive"
        bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh a2 2>/dev/null
      end

      # Startup dashboard
      clear
      printf "\x1b[1;34mWelcome to your shell, %s!\x1b[0m\n" (whoami)
      date "+%A, %B %d, %Y - %I:%M %p"
      get_system_info
      get_network_info
      get_disk_usage
      echo -e "\n4.Rclone - Mounted Drives"
      echo -e "-----------------------"
      mount | grep rclone
      printf "\n\x1b[32mHave a productive day!\x1b[0m\n"

      # ASCII Art
      echo '
           _               _
        _ /\ \           /\ \
      / \_\\ \ \         /  \ \
     / / / \ \ \       / /\ \ \
    / / /   \ \ \      \/_/\ \ \
    \ \ \____\ \ \         / / /
     \ \________\ \       / / /
      \/________/\ \     / / /  _
                \ \ \   / / /_/\_\
                 \ \_\ / /_____/ /
                  \/_/ \________/
      '
      echo "Fish aliases loaded successfully!"
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # STARSHIP PROMPT
  # ═══════════════════════════════════════════════════════════════════════════

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # GIT
  # ═══════════════════════════════════════════════════════════════════════════

  programs.git = {
    enable = true;
    userName = "diegonmarcos";
    userEmail = "diegonmarcos@gmail.com";

    extraConfig = {
      safe.directory = "*";
      core.excludesfile = "/home/diego/.gitignore_global";
      credential = {
        "https://github.com".helper = "!/home/diego/.local/bin/gh auth git-credential";
        "https://gist.github.com".helper = "!/home/diego/.local/bin/gh auth git-credential";
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # KDE PLASMA CONFIGURATION FILES
  # ═══════════════════════════════════════════════════════════════════════════

  home.file = {
    # Theme & Colors (Breeze Dark)
    ".config/kdeglobals".text = ''
      [ColorEffects:Disabled]
      ChangeSelectionColor=
      Color=56,56,56
      ColorAmount=0
      ColorEffect=0
      ContrastAmount=0.65
      ContrastEffect=1
      Enable=
      IntensityAmount=0.1
      IntensityEffect=2

      [ColorEffects:Inactive]
      ChangeSelectionColor=true
      Color=112,111,110
      ColorAmount=0.025
      ColorEffect=2
      ContrastAmount=0.1
      ContrastEffect=2
      Enable=false
      IntensityAmount=0
      IntensityEffect=0

      [Colors:Button]
      BackgroundAlternate=30,87,116
      BackgroundNormal=49,54,59
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Complementary]
      BackgroundAlternate=30,87,116
      BackgroundNormal=42,46,50
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Header]
      BackgroundAlternate=42,46,50
      BackgroundNormal=49,54,59
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Header][Inactive]
      BackgroundAlternate=49,54,59
      BackgroundNormal=42,46,50
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Selection]
      BackgroundAlternate=30,87,116
      BackgroundNormal=61,174,233
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=252,252,252
      ForegroundInactive=161,169,177
      ForegroundLink=253,188,75
      ForegroundNegative=176,55,69
      ForegroundNeutral=198,92,0
      ForegroundNormal=252,252,252
      ForegroundPositive=23,104,57
      ForegroundVisited=155,89,182

      [Colors:Tooltip]
      BackgroundAlternate=42,46,50
      BackgroundNormal=49,54,59
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:View]
      BackgroundAlternate=35,38,41
      BackgroundNormal=27,30,32
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [Colors:Window]
      BackgroundAlternate=49,54,59
      BackgroundNormal=42,46,50
      DecorationFocus=61,174,233
      DecorationHover=61,174,233
      ForegroundActive=61,174,233
      ForegroundInactive=161,169,177
      ForegroundLink=29,153,243
      ForegroundNegative=218,68,83
      ForegroundNeutral=246,116,0
      ForegroundNormal=252,252,252
      ForegroundPositive=39,174,96
      ForegroundVisited=155,89,182

      [General]
      ColorScheme=BreezeDark
      ColorSchemeHash=babca25f3a5cf7ece26a85de212ab43d0a141257
      Name=Breeze Dark

      [KDE]
      LookAndFeelPackage=org.kde.breezedark.desktop
      widgetStyle=Breeze

      [Icons]
      Theme=breeze-dark

      [WM]
      activeBackground=49,54,59
      activeBlend=252,252,252
      activeForeground=252,252,252
      inactiveBackground=42,46,50
      inactiveBlend=161,169,177
      inactiveForeground=161,169,177
    '';

    # KWin - Night Color, Tiling
    ".config/kwinrc".text = ''
      [Desktops]
      Id_1=63e7e852-00b9-4768-b3f8-11f2cdc5d193
      Number=1
      Rows=1

      [NightColor]
      Active=true
      Mode=Constant
      NightTemperature=2200

      [Tiling]
      padding=4

      [Xwayland]
      Scale=1.5
    '';

    # Plasma Theme
    ".config/plasmarc".text = ''
      [Theme]
      name=breeze-dark
    '';

    # GTK 3 Theme
    ".config/gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-application-prefer-dark-theme=1
      gtk-theme-name=Breeze-Dark
    '';

    # GTK 4 Theme
    ".config/gtk-4.0/settings.ini".text = ''
      [Settings]
      gtk-application-prefer-dark-theme=1
      gtk-theme-name=Breeze-Dark
    '';

    # Konsole Dark Theme Profile
    ".local/share/konsole/Dark.profile".text = ''
      [Appearance]
      ColorScheme=Breeze
      Font=Monospace,11,-1,5,50,0,0,0,0,0

      [General]
      Name=Dark
      Parent=FALLBACK/

      [Scrolling]
      HistoryMode=1
      HistorySize=10000

      [Terminal Features]
      BlinkingCursorEnabled=false
    '';

    # Keyboard Layout - Spanish
    ".config/kxkbrc".text = ''
      [Layout]
      DisplayNames=
      LayoutList=es
      LayoutLoopCount=-1
      Model=pc105
      Options=
      ResetOldOptions=false
      ShowFlag=false
      ShowLabel=true
      ShowLayoutIndicator=true
      ShowSingle=false
      SwitchMode=Global
      Use=true
    '';

    # Locale - Spanish date format (dd/mm/yyyy), 24h time
    ".config/plasma-localerc".text = ''
      [Formats]
      LC_TIME=es_ES.UTF-8
      LC_MEASUREMENT=es_ES.UTF-8
      LC_MONETARY=es_ES.UTF-8
      LC_NUMERIC=es_ES.UTF-8
    '';

    # Touchpad - Tap drag lock enabled (Surface)
    ".config/kcminputrc".text = ''
      [Libinput][1118][2479][Microsoft Surface 045E:09AF Touchpad]
      TapDragLock=true

      [Mouse]
      X11LibInputXAccelProfileFlat=true
    '';
  };
}
