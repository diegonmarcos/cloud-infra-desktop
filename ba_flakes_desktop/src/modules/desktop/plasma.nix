# KDE Plasma configuration - FULL NIX CONTROL
# Requires plasma-manager input in flake.nix
{ config, pkgs, lib, ... }:

let
  # Unified system wallpaper (declared in cloud-data-wallpaper.json, also
  # consumed by aa_nixos-surface_host's SDDM Background). Resolved against
  # the kdePackages.plasma-workspace-wallpapers derivation directly.
  wallpaperJson = builtins.fromJSON (builtins.readFile ./cloud-data-wallpaper.json);
  wallpaperPath = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/${wallpaperJson.wallpaper.theme}/contents/images/${wallpaperJson.wallpaper.image}";

  # Unified energy/power policy (cloud-data-power.json). Same SoT consumed by
  # the host flake (UPower.conf, logind lid + power button, kernel cmdline).
  pwrJson = builtins.fromJSON (builtins.readFile ./cloud-data-power.json);
  thr     = pwrJson.thresholds;
  idleAC  = pwrJson.idle_minutes.ac;
  idleBat = pwrJson.idle_minutes.battery;
  banned  = pwrJson.actions.never;
  pdGuard = name: v:
    if builtins.elem v banned
    then throw "plasma.nix: ${name}=${v} is in actions.never (Surface S3 is broken)"
    else v;
  # PowerDevil action enum (from daemon/powerdevilenums.h): NoAction=0,
  # Sleep=1, Hibernate=2, Shutdown=8, LockScreen=32.
  pdAction = v:
    if v == "hibernate" then 2
    else if v == "lock" then 32
    else if v == "poweroff" then 8
    else throw "plasma.nix: pdAction(${v}) — unsupported (sleep/suspend banned)";
  critAction = pdAction (pdGuard "actions.critical" pwrJson.actions.critical);
  lidAction  = pdAction (pdGuard "events.lid_close" pwrJson.events.lid_close.battery);
in

{
  imports = [
    # konsole-ssh-manager-quick-commands.nix used to be pulled sideways from
    # here — app_especific is now always in userModules (flake.nix) and owns
    # it, so this profile no longer needs its own copy.
    ./session-restore.nix    # Plasma's native session save/restore (inert; loginMode moved out)
    ./default-session.nix    # DECLARATIVE default 4-desktop login layout (data: default-session.json)
    ./cloud-terminal.nix     # pull Cloud Terminal from its GH Release (version-guarded)
    ./bottom-panel.nix       # DECLARATIVE bottom panel (data: bottom-panel.json)
    ./top-panel.nix          # DECLARATIVE top panel  (data: top-panel.json)
  ];

  # Fix system tray visibility after home-manager switch
  # Plasma reads shownItems from the PRIVATE systemtray containment, not the applet
  home.activation.fixSystemTray = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    APPLETS_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPLETS_FILE" ]; then
      # nixos-systray / cloud-systray = Control Panel tray apps. Listing them in
      # shownItems forces them ALWAYS visible in the tray (not the overflow).
      ALL_ITEMS="org.kde.plasma.battery,org.kde.plasma.bluetooth,org.kde.plasma.brightness,org.kde.plasma.networkmanagement,org.kde.plasma.volume,org.kde.plasma.clipboard,org.kde.plasma.devicenotifier,org.kde.plasma.notifications,org.kde.kdeconnect,org.kde.kscreen,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.cameraindicator,org.kde.plasma.manage-inputmethod,org.kde.plasma.mediacontroller,nixos-systray,cloud-systray"

      # Find the PRIVATE systemtray containment ID (plugin=org.kde.plasma.private.systemtray)
      TRAY_ID=$(${pkgs.gawk}/bin/awk '
        /^\[Containments\]\[[0-9]+\]$/ { current_id = gensub(/.*\[([0-9]+)\]$/, "\\1", "g") }
        /^plugin=org\.kde\.plasma\.private\.systemtray$/ { print current_id; exit }
      ' "$APPLETS_FILE")

      if [ -n "$TRAY_ID" ]; then
        GENERAL_SECTION="[Containments][$TRAY_ID][General]"

        # Check if [General] section exists for this containment
        if grep -qF "$GENERAL_SECTION" "$APPLETS_FILE"; then
          # Remove existing shownItems/hiddenItems in this section
          ${pkgs.gnused}/bin/sed -i "/^\[Containments\]\[$TRAY_ID\]\[General\]$/,/^\[/ {
            /^shownItems=/d
            /^hiddenItems=/d
          }" "$APPLETS_FILE"
          # Add shownItems and hiddenItems after the section header
          ${pkgs.gnused}/bin/sed -i "/^\[Containments\]\[$TRAY_ID\]\[General\]$/a shownItems=$ALL_ITEMS\nhiddenItems=" "$APPLETS_FILE"
        else
          # Section doesn't exist, append it at end of file
          echo "" >> "$APPLETS_FILE"
          echo "$GENERAL_SECTION" >> "$APPLETS_FILE"
          echo "shownItems=$ALL_ITEMS" >> "$APPLETS_FILE"
          echo "hiddenItems=" >> "$APPLETS_FILE"
        fi
      fi
    fi
  '';

  # Configure battery widget to show percentage instead of icon
  home.activation.fixBatteryPercentage = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    APPLETS_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPLETS_FILE" ]; then
      # Find the battery applet section: [Containments][X][Applets][Y] where plugin=org.kde.plasma.battery
      BATTERY_SECTION=$(${pkgs.gawk}/bin/awk '
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ { section = $0 }
        /^plugin=org\.kde\.plasma\.battery$/ { gsub(/\[|\]/, " ", section); split(section, a); printf "[Containments][%s][Applets][%s]", a[2], a[4]; exit }
      ' "$APPLETS_FILE")

      if [ -n "$BATTERY_SECTION" ]; then
        CONFIG_SECTION="$BATTERY_SECTION[Configuration][General]"

        # Check if Configuration/General section exists
        if grep -qF "$CONFIG_SECTION" "$APPLETS_FILE"; then
          # Update existing showPercentage
          ${pkgs.gnused}/bin/sed -i "s/^showPercentage=.*/showPercentage=true/" "$APPLETS_FILE"
          # Add if not present
          if ! grep -q "^showPercentage=" "$APPLETS_FILE"; then
            ${pkgs.gnused}/bin/sed -i "/^$(echo "$CONFIG_SECTION" | ${pkgs.gnused}/bin/sed 's/\[/\\[/g; s/\]/\\]/g')$/a showPercentage=true" "$APPLETS_FILE"
          fi
        else
          # Section doesn't exist, append it
          echo "" >> "$APPLETS_FILE"
          echo "$CONFIG_SECTION" >> "$APPLETS_FILE"
          echo "showPercentage=true" >> "$APPLETS_FILE"
        fi
      fi
    fi
  '';

  # Lock screen wallpaper — matches the desktop + SDDM wallpaper (declared in
  # cloud-data-wallpaper.json, consumed via wallpaperPath in this file's let-binding).
  # plasma-manager's configFile escapes ] [ in section names (turns them into \x5d\x5b),
  # which breaks KDE's hierarchical [Greeter][Wallpaper][org.kde.image][General] section.
  # kwriteconfig6 with multiple --group flags produces the correct nested-group syntax.
  home.activation.lockScreenWallpaper = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    LOCK_RC="$HOME/.config/kscreenlockerrc"
    LOCK_IMG="${wallpaperPath}"
    # Strip stale sections (old buddha path + plasma-manager's escaped duplicate)
    if [ -f "$LOCK_RC" ]; then
      ${pkgs.gnused}/bin/sed -i \
        -e '/^\[Greeter\\x5d\\x5bWallpaper\\x5d\\x5borg\.kde\.image\\x5d\\x5bGeneral\]$/,/^\[/{/^\[Greeter\\x5d\\x5bWallpaper\\x5d\\x5borg\.kde\.image\\x5d\\x5bGeneral\]$/d;/^\[/!d}' \
        "$LOCK_RC"
    fi
    ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file kscreenlockerrc \
      --group Greeter --group Wallpaper --group org.kde.image --group General \
      --key Image "$LOCK_IMG"
    ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file kscreenlockerrc \
      --group Greeter --group Wallpaper --group org.kde.image --group General \
      --key PreviewImage "$LOCK_IMG"
  '';

  # PowerDevil [*][SuspendAndShutdown] groups via kwriteconfig6.
  # plasma-manager's configFile mangles nested-bracket sections (writes them
  # as [X\x5d\x5bY] which PowerDevil ignores), so we use kwriteconfig6 with
  # multiple --group flags. Idle auto-hibernate values come from
  # cloud-data-power.json (idle_minutes.{ac,battery}.hibernate, in minutes;
  # null disables idle-triggered hibernation for that power source — encoded
  # here as AutoSuspendIdleTimeoutSec=0, PowerDevil's "never" sentinel, with
  # AutoSuspendAction forced to NoAction(0) too so a stale timeout can't
  # still fire the action). [LowBattery] tracks the Battery value.
  home.activation.powerDevilSuspend = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    PD_RC="$HOME/.config/powerdevilrc"
    AC_SEC=${toString (if idleAC.hibernate  == null then 0 else idleAC.hibernate  * 60)}
    BAT_SEC=${toString (if idleBat.hibernate == null then 0 else idleBat.hibernate * 60)}
    AC_ACT=${toString (if idleAC.hibernate  == null then 0 else critAction)}
    BAT_ACT=${toString (if idleBat.hibernate == null then 0 else critAction)}

    # Strip stale escaped duplicates plasma-manager may have written.
    if [ -f "$PD_RC" ]; then
      ${pkgs.gnused}/bin/sed -i \
        -e '/^\[AC\\x5d\\x5bSuspendAndShutdown\]$/,/^\[/{/^\[AC\\x5d\\x5bSuspendAndShutdown\]$/d;/^\[/!d}' \
        -e '/^\[Battery\\x5d\\x5bSuspendAndShutdown\]$/,/^\[/{/^\[Battery\\x5d\\x5bSuspendAndShutdown\]$/d;/^\[/!d}' \
        -e '/^\[LowBattery\\x5d\\x5bSuspendAndShutdown\]$/,/^\[/{/^\[LowBattery\\x5d\\x5bSuspendAndShutdown\]$/d;/^\[/!d}' \
        -e '/^\[AC\\x5d\\x5bHandleButtonEvents\]$/,/^\[/{/^\[AC\\x5d\\x5bHandleButtonEvents\]$/d;/^\[/!d}' \
        -e '/^\[Battery\\x5d\\x5bHandleButtonEvents\]$/,/^\[/{/^\[Battery\\x5d\\x5bHandleButtonEvents\]$/d;/^\[/!d}' \
        -e '/^\[LowBattery\\x5d\\x5bHandleButtonEvents\]$/,/^\[/{/^\[LowBattery\\x5d\\x5bHandleButtonEvents\]$/d;/^\[/!d}' \
        "$PD_RC"
    fi

    KW=${pkgs.kdePackages.kconfig}/bin/kwriteconfig6
    for src_sec_act in "AC:$AC_SEC:$AC_ACT" "Battery:$BAT_SEC:$BAT_ACT" "LowBattery:$BAT_SEC:$BAT_ACT"; do
      src=''${src_sec_act%%:*}
      rest=''${src_sec_act#*:}
      sec=''${rest%%:*}
      act=''${rest#*:}
      "$KW" --file powerdevilrc --group "$src" --group SuspendAndShutdown \
            --key AutoSuspendAction         "$act"
      "$KW" --file powerdevilrc --group "$src" --group SuspendAndShutdown \
            --key AutoSuspendIdleTimeoutSec "$sec"
    done
  '';

  programs.plasma = {
    enable = true;

    # AUTHORITATIVE plasma config. plasma-manager regenerates the full config
    # (panels incl.) from these nix declarations on every switch, instead of
    # merging into whatever the live appletsrc happens to hold. This is the
    # root-cause fix for widget/panel DUPLICATE ACCUMULATION: the old hand-made
    # top panel + its piled-up monitor applets can no longer survive a switch —
    # only bottom-panel.nix + top-panel.nix define what exists. Everything the
    # desktop needs must be declared here (it is: panels, theme, shortcuts,
    # kwin, configFile). Live-only tweaks not in nix are intentionally dropped.
    overrideConfig = true;

    # ─────────────────────────────────────────────────────────────────
    # Appearance - FULL DARK THEME
    # ─────────────────────────────────────────────────────────────────
    workspace = {
      theme = "breeze-dark";
      colorScheme = "BreezeDark";
      cursor.theme = "breeze_cursors";
      iconTheme = "breeze-dark";
      lookAndFeel = "org.kde.breezedark.desktop";
      wallpaper = wallpaperPath;
    };

    # Window decorations - Dark
    kwin.titlebarButtons = {
      left = [ "on-all-desktops" "keep-above-windows" ];
      right = [ "minimize" "maximize" "close" ];
    };

    # Fonts
    fonts = {
      general = {
        family = "Noto Sans";
        pointSize = 10;
      };
      fixedWidth = {
        family = "JetBrains Mono";
        pointSize = 10;
      };
    };

    # ─────────────────────────────────────────────────────────────────
    # Keyboard Shortcuts
    # ─────────────────────────────────────────────────────────────────
    shortcuts = {
      kwin = {
        "Window Close" = "Alt+F4";
        "Window Maximize" = "Meta+Up";
        "Window Minimize" = "Meta+Down";
        "Switch to Desktop 1" = "Meta+1";
        "Switch to Desktop 2" = "Meta+2";
        "Switch to Desktop 3" = "Meta+3";
        "Switch to Desktop 4" = "Meta+4";
        "Switch to Previous Desktop" = "Meta+Ctrl+Left";
        "Switch to Next Desktop" = "Meta+Ctrl+Right";
        "Window to Desktop 1" = "Meta+Shift+1";
        "Window to Desktop 2" = "Meta+Shift+2";
        "Window to Desktop 3" = "Meta+Shift+3";
        "Window to Desktop 4" = "Meta+Shift+4";
      };
      plasmashell = {
        "show-on-mouse-pos" = "Meta+V";
      };
      "my-konsole.desktop"."_launch" = "Meta+Return";
      "org.kde.dolphin.desktop"."_launch" = "Meta+E";
    };

    # ─────────────────────────────────────────────────────────────────
    # Window Manager (KWin)
    # ─────────────────────────────────────────────────────────────────
    kwin = {
      effects.shakeCursor.enable = true;
      virtualDesktops = {
        number = 4;
        rows = 1;
        names = [ "Desk1" "Desk2" "Desk3" "Desk4" ];
      };

      # Night Light always on (2200K warm)
      nightLight = {
        enable = true;
        mode = "constant";
        temperature = {
          day = 2200;
          night = 2200;
        };
      };
    };

    # window-rules are now generated by ./session-template.nix from
    # ./session-template.json (data-driven). Adding new pinned-position
    # apps means editing the JSON, not adding more rules here.

    # ─────────────────────────────────────────────────────────────────
    # Startup script (runs once when config changes)
    # For every-login startup, use xdg.configFile autostart below
    # ─────────────────────────────────────────────────────────────────

    # ─────────────────────────────────────────────────────────────────
    # Panel Configuration — NOW DECLARATIVE (./bottom-panel.nix)
    # ─────────────────────────────────────────────────────────────────
    # The bottom panel is defined declaratively in ./bottom-panel.nix
    # (data: ./bottom-panel.json). plasma-manager recreates it on every
    # switch — the JSON is the source of truth, not the live appletsrc.
    # The old "user-managed / manual" note below is retained for context;
    # the ID-churn caveat is accepted as the declarative tradeoff.
    #
    # ═══════════════════════════════════════════════════════════════
    # CURRENT PANEL LAYOUT (Updated: 2026-02-01)
    # ═══════════════════════════════════════════════════════════════
    # Bottom panel, height 44, no hiding, not floating
    #
    # Widgets (left to right):
    #   - Kickoff (icon: nix-snowflake-white)
    #   - Pager (show desktop numbers)
    #   - Margins Separator
    #   - Icon Tasks (Dolphin, Konsole, Obsidian, Brave, Waydroid, Settings)
    #   - Panel Spacer
    #   - System Monitors:
    #       • CPU (org.kde.plasma.systemmonitor.cpu)
    #       • CPU Core (org.kde.plasma.systemmonitor.cpucore)
    #       • Memory (org.kde.plasma.systemmonitor.memory)
    #       • Disk Usage (org.kde.plasma.systemmonitor.diskusage)
    #       • Disk Activity (org.kde.plasma.systemmonitor.diskactivity)
    #       • Network (org.kde.plasma.systemmonitor.net)
    #   - Margins Separator
    #   - Weather (org.kde.plasma.weather)
    #   - System Tray (all items visible)
    #   - Digital Clock (24h, dd-MM-yyyy below time, Monday first)
    #   - User Switcher
    # ═══════════════════════════════════════════════════════════════

    # ─────────────────────────────────────────────────────────────────
    # KDE Config Files (via configFile - non-destructive merge)
    # ─────────────────────────────────────────────────────────────────
    configFile = {
      # NOTE: Panel/widget containment IDs (like 244, 308) are NOT configured here
      # because Plasma assigns dynamic IDs. Panel config is user-managed.
      # The activation script (fixSystemTray) handles system tray visibility dynamically.

      # Mouse/Touchpad settings
      "kcminputrc"."Libinput.1267.12693.ELAN0732:00 04F3:3195 Touchpad" = {
        NaturalScroll = true;
        TapToClick = true;
        TapAndDrag = true;
        TapDragLock = true;
        ClickMethod = 2;  # clickfinger (1=button_areas, 2=clickfinger)
      };
      # Microsoft Surface Type Cover touchpad (alternate device ID)
      "kcminputrc"."Libinput.25.2479.Microsoft Surface 045E:09AF Touchpad" = {
        NaturalScroll = true;
        TapToClick = true;
        TapAndDrag = true;
        TapDragLock = true;
        ClickMethod = 2;  # clickfinger
      };
      "kcminputrc"."Mouse" = {
        cursorSize = 24;
        X11LibInputXAccelProfileFlat = true;
      };

      # Full Breeze Dark Color Scheme.
      #
      # ColorEffects:Disabled/Inactive and Colors:Button/Selection/Tooltip/
      # View/Window are DELIBERATELY NOT declared here — they're in
      # plasma-manager's own colorscheme.nix `ignoreKeys` list, which sets
      # persistent=mkDefault true on those keys as soon as workspace.
      # colorScheme = "BreezeDark" (below) is set. Also declaring a raw
      # value for the SAME keys here made write_config.py reject the whole
      # activation: "Persistency enabled for key ... A value cannot be
      # given when persistency is enabled" — plasma-manager already applies
      # Breeze Dark's correct values for these via colorScheme, natively,
      # without the conflict. Verified against plasma-manager's actual
      # source (lib/colorscheme.nix) before removing — this broke every
      # switch on this machine until removed.
      "kdeglobals"."Colors:Complementary" = {
        BackgroundAlternate = "30,87,116";
        BackgroundNormal = "42,46,50";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Header" = {
        BackgroundAlternate = "42,46,50";
        BackgroundNormal = "49,54,59";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."Colors:Header][Inactive" = {
        BackgroundAlternate = "49,54,59";
        BackgroundNormal = "42,46,50";
        DecorationFocus = "61,174,233";
        DecorationHover = "61,174,233";
        ForegroundActive = "61,174,233";
        ForegroundInactive = "161,169,177";
        ForegroundLink = "29,153,243";
        ForegroundNegative = "218,68,83";
        ForegroundNeutral = "246,116,0";
        ForegroundNormal = "252,252,252";
        ForegroundPositive = "39,174,96";
        ForegroundVisited = "155,89,182";
      };
      "kdeglobals"."General" = {
        # ColorScheme/ColorSchemeHash deliberately NOT declared — same
        # persistency conflict as the Colors:* groups above:
        # workspace.colorScheme = "BreezeDark" (below) already writes
        # these exact values via plasma-manager's own colorScheme
        # mechanism, which marks General.ColorScheme persistent=true.
        # my-konsole is the default terminal. ponytail: Dolphin's "Open Terminal
        # here" passes a workdir the Tauri app doesn't yet consume — opens at
        # $HOME for now; add a --workdir arg to the app if that matters.
        TerminalApplication = "my-konsole";
        TerminalService = "my-konsole.desktop";
      };
      # kdeglobals.Icons.Theme and kdeglobals.KDE.LookAndFeelPackage
      # deliberately NOT declared — same persistency conflict: both are
      # theme-identity keys plasma-manager's colorScheme mechanism already
      # sets to the Breeze Dark values via workspace.colorScheme below.

      # Dolphin - Terminal integration
      "dolphinrc"."General" = {
        ShowFullPath = true;
        ShowFullPathInTitlebar = true;
        # Speculative: force re-list on window focus-in. Key is not part of
        # the documented Plasma 6 dolphinrc schema (was present in some KDE
        # forks). Harmless if ignored. The REAL fix for stale Dolphin views
        # after bursty filesystem ops (git rm -rf / rsync --delete / cargo
        # build) is raising inotify limits in the NixOS host flake:
        #   boot.kernel.sysctl = {
        #     "fs.inotify.max_user_watches"   = 1048576;
        #     "fs.inotify.max_user_instances" = 1024;
        #     "fs.inotify.max_queued_events"  = 65536;
        #   };
        AutoRefresh = true;
      };
      # Disable VCS overlay plugins. Default ("Git") makes Dolphin run
      # `git status --porcelain --ignored` on every directory it shows,
      # walking ignored files (rust target/, node_modules, dist/, …) and
      # auto-refreshing on inotify events. With ~/git holding cloud +
      # cloud-data + unix + front + vault + tools that's 6+ cores of
      # constant git activity for status badges nobody uses. Disable.
      # Caught live (5/5 git samples had .dolphin-wrappe as parent):
      #   git --no-optional-locks status --porcelain -z -u --ignored
      "dolphinrc"."VersionControl" = {
        enabledPlugins = "";
      };

      # Terminal panel config - uses konsolepart KPart plugin
      "dolphinrc"."Terminal Panel" = {
        ShowTerminal = true;
      };

      # ksmserverrc.General.loginMode is now declared by ./session-restore.nix
      # — it toggles between restorePreviousSession (capture mode) and
      # restoreSavedSession (deploy mode) based on whether session-snapshot/
      # has been populated. See that module for the workflow.

      # ─────────────────────────────────────────────────────────────────
      # KWin Window Behavior — fix focus stealing on Surface touchpad
      # FocusStealingPreventionLevel: 0=None 1=Low 2=Medium 3=High 4=Extreme
      # Default (1) misinterprets touchpad clicks as focus-steal attempts on Wayland
      # ─────────────────────────────────────────────────────────────────
      "kwinrc"."Windows" = {
        FocusStealingPreventionLevel = 0;
        FocusPolicy = "ClickToFocus";
        ClickRaise = true;
        RollOverDesktops = true;
      };

      # ─────────────────────────────────────────────────────────────────
      # KWin Desktop Effects
      # ─────────────────────────────────────────────────────────────────
      "kwinrc"."Plugins" = {
        cubeEnabled = true;
        cubeslideEnabled = true;
        # DISABLED: diminactive hooks into focus-change events and interferes
        # with window activation on Surface Wayland touchpad
        diminactiveEnabled = false;
        wobblywindowsEnabled = true;
        translucencyEnabled = true;
        # DISABLED: shakecursor monitors touchpad movement patterns and
        # intercepts/delays click events on Wayland — causes lost clicks on Surface
        shakecursorEnabled = lib.mkForce false;
      };

      # Cube effect settings
      "kwinrc"."Effect-cube" = {
        BorderActivate = 9;  # No border activation
        TouchBorderActivate = 9;
      };

      # Dim inactive settings (how much to dim)
      "kwinrc"."Effect-diminactive" = {
        Strength = 15;  # 15% dimming
      };

      # Wobbly windows settings
      "kwinrc"."Effect-wobblywindows" = {
        Drag = 85;
        Stiffness = 10;
        WobblynessLevel = 1;
      };

      # Translucency settings (moving/resizing windows)
      "kwinrc"."Effect-translucency" = {
        MoveResize = 80;  # 80% opacity when moving
      };

      # Virtual keyboard DISABLED — VirtualKeyboard=true causes KWin to
      # redirect focus/input back to the active window, breaking click-to-switch
      # on Surface Wayland touchpad. Use on-screen keyboard apps directly instead.
      # (maliit-keyboard also removed — causes trackpad click freeze)

      # Lock screen virtual keyboard
      "kscreenlockerrc"."Greeter" = {
        VirtualKeyboard = true;
        VirtualKeyboardTheme = "breeze";
      };

      # ─────────────────────────────────────────────────────────────────
      # Power Management — single-bracket sections only.
      #
      # Lid handling: lidSwitch=lock comes from configuration_security.nix
      # (logind level), which is the path that actually locks the screen.
      # PowerDevil's [*][HandleButtonEvents] are intentionally NOT declared
      # here because plasma-manager's configFile escapes nested-bracket
      # section names ([X][Y] → [X\x5d\x5bY]) which PowerDevil doesn't
      # read. logind already covers the use case.
      #
      # Nested-bracket sections that PowerDevil DOES need (the
      # [*][SuspendAndShutdown] family) are written via kwriteconfig6 in
      # home.activation.powerDevilSuspend below.
      # ─────────────────────────────────────────────────────────────────
      #
      # Critical/Low/Warn thresholds + critical action — sourced from
      # cloud-data-power.json. Same SoT used by the host UPower.conf so
      # PowerDevil and upowerd act on identical numbers (both Tier 1 — they
      # share the SAM data path). Action enum from daemon/powerdevilenums.h:
      # NoAction=0, Sleep=1, Hibernate=2, Shutdown=8, LockScreen=32.
      #
      # Note: this rule depends on upowerd reporting a numeric percentage.
      # SAM voltage=0 glitches → percentage NaN → this never fires. The
      # SAM-independent safety net lives at:
      #   aa_nixos-surface_host/src/modules/configuration_system-protection-battery.nix
      "powerdevilrc"."BatteryManagement" = {
        BatteryCriticalAction = critAction;       # actions.critical (= 2 / Hibernate)
        BatteryCriticalLevel  = thr.critical_pct; # thresholds.critical_pct
        BatteryLowLevel       = thr.low_pct;      # thresholds.low_pct
      };

      # Lock-screen idle (kscreenlocker, not PowerDevil). Timeout is in
      # MINUTES, applied identically on AC and Battery — security shouldn't
      # depend on power source. Sourced from idle_minutes.battery.lock.
      "kscreenlockerrc"."Daemon" = {
        Autolock = true;
        Timeout  = idleBat.lock;
      };

      # Keyboard layout switching disabled 2026-07-31 (user request) — single
      # default layout only, no Alt+Shift cycling. List kept for a quick
      # revert; Use=false is what actually turns switching off.
      "kxkbrc"."Layout" = {
        LayoutList = "es,gb,pt,de";
        DisplayNames = "Spanish,British,Portuguese,German";
        Options = "grp:alt_shift_toggle";  # Switch layouts with Alt+Shift
        ResetOldOptions = true;
        SwitchMode = "Global";
        Use = false;
        VariantList = ",,,";  # Default variants for each layout
      };

      # kdeglobals.WM (titlebar colors) deliberately NOT declared — same
      # persistency conflict as the other theme-identity keys above;
      # workspace.colorScheme = "BreezeDark" already covers it.
    };
  };

  # xembedsniproxy: re-enabled (kernel ≥6.17.13 fixes the Surface BTN_0 stuck-key
  # bug that caused mouse click freezes under XEmbed — we're on 6.19.8+).

  # ─────────────────────────────────────────────────────────────────
  # GTK Apps in Plasma
  # ─────────────────────────────────────────────────────────────────
  gtk = {
    enable = true;
    theme = {
      name = "Breeze-Dark";
      package = pkgs.kdePackages.breeze-gtk;
    };
    iconTheme = {
      name = "breeze-dark";
      package = pkgs.kdePackages.breeze-icons;
    };
    cursorTheme = {
      name = "breeze_cursors";
      package = pkgs.kdePackages.breeze;
    };
  };

  # Custom Desktop Entries — waydroid entry REMOVED 2026-07-01 (waydroid disabled).

  # ─────────────────────────────────────────────────────────────────
  # ─────────────────────────────────────────────────────────────────
  # Baloo file indexer — declarative config
  # ─────────────────────────────────────────────────────────────────
  # Strategy: BASIC INDEXING ONLY (filenames + filesystem metadata).
  # No content extraction — content search is on-demand via `rg`/`grep`.
  #
  # Why: content extraction is the heavy phase. It opens every PDF /
  # source file / archive, runs kfilemetadata extractors, parses, and
  # writes Xapian rows. On btrfs+LUKS that pipeline pegs CPU + disk.
  # Filenames cost ~one stat + one DB row — cheap. So we keep the cheap
  # half (broad filename coverage for Dolphin Content mode + Krunner)
  # and discard the expensive half (PDF/source full-text search), which
  # `rg` does better at query time anyway.
  #
  # Three knobs:
  #   only basic indexing=true      no content extraction. Ever.
  #   exclude filters=...           basenames Baloo skips entirely
  #                                 (build/cache/VCS churn — high
  #                                 file-count + frequent rewrites).
  #                                 Comma-separated. Replaces Baloo's
  #                                 baked-in default with a superset.
  #   exclude folders[$e]=...       subtrees pruned wholesale (browser
  #                                 profile DBs, /nix store, mounts,
  #                                 system caches). [$e] expands $HOME.
  #
  # Includes (now filename-searchable, were excluded before):
  #   $HOME/git        source files (subdirs like target/, node_modules/,
  #                    .git/ still skipped via exclude filters)
  #   $HOME/Backups    archive names searchable
  #   $HOME/Downloads  installer / archive names searchable
  #
  # Source of truth: this file. Re-rendered on every home-manager switch.
  # Apply the change WITHOUT logout via:
  #   balooctl6 disable && balooctl6 purge && balooctl6 enable
  xdg.configFile."baloofilerc".text = ''
    [General]
    dbVersion=2
    only basic indexing=true
    folders[$e]=$HOME/bin

    [Basic Settings]
    Indexing-Enabled=true
  '';

  # ─────────────────────────────────────────────────────────────────
  # Dolphin — disable VCS git plugin (the load-6 culprit)
  # ─────────────────────────────────────────────────────────────────
  # Dolphin's "Version Control: Git" plugin runs `git status --porcelain
  # --ignored` on every directory shown, and re-runs it on inotify events.
  # `--ignored` walks every git-ignored file too — which on this box
  # means rust target/ (~100k objects), node_modules, dist/, .next, etc.
  # With ~/git holding cloud + cloud-data + unix + front + vault + tools
  # this turns into 6+ cores of git constantly walking working trees
  # for tiny status overlay icons nobody uses.
  #
  # Evidence (caught live, 5/5 git samples had .dolphin-wrappe as parent):
  #   git --no-optional-locks status --porcelain -z -u --ignored
  #   git -c core.quotepath=false ls-files --others --exclude-standard
  #
  # Fix: empty enabledPlugins under [VersionControl]. Disables ALL VCS
  # overlays (git/svn/hg). Dolphin still works fully — it just doesn't
  # decorate file icons with git-status badges.
  #
  # To re-enable later (e.g. for a small repo) toggle in Dolphin →
  # Configure → General → Services → "Git" checkbox.
  #
  # Apply: ba_flakes_desktop/build.sh switch  (then close + reopen Dolphin
  # OR `kquitapp6 dolphin` — the running Dolphin holds the old config in
  # memory until restart).
  # NOTE: dolphinrc lives under programs.plasma.configFile (line ~464)
  # — plasma-manager owns the file and writes it via its python helper,
  # which conflicts with xdg.configFile (read-only /nix/store symlink
  # vs python trying to open(..., "w")). VCS plugins disabled there.

  # ─────────────────────────────────────────────────────────────────
  # htop — 5-tab dashboard for full system breakdown
  # ─────────────────────────────────────────────────────────────────
  # htop 3.x supports multiple "screens" (tabs, switch with Tab/Shift-Tab
  # or Fn-keys). This config defines 5:
  #
  #   1. MAIN     — generalist process list (PID/USER/PRI/NI/VIRT/RES/
  #                 STATE/%CPU/%MEM/TIME), sorted by %CPU.
  #   2. CPU      — CPU-pressure forensics: %CPU + normalized %CPU,
  #                 thread count (NLWP), context switches (CTXT),
  #                 page faults (MAJFLT/MINFLT) — pinpoints what's
  #                 burning cores AND what's churning kernel.
  #   3. MEMORY   — VIRT/RES/SHR + PSS (proportional, accurate when
  #                 sharing) + SWAP per-process. Sorted by RES.
  #   4. DISK     — IO_RATE + read/write split + IO_PRIORITY +
  #                 PERCENT_IO_DELAY (time spent in iowait). Sorted
  #                 by IO_RATE so disk hogs surface immediately.
  #   5. GPU      — PERCENT_GPU + GPU_TIME (Intel Iris Xe via
  #                 /sys/class/drm/card*/clients). Sorted by %GPU.
  #
  # Header is global (htop limitation — same top bars on every screen)
  # and uses the four-column layout to pack maximum info:
  #   col0: per-CPU usage bars + load average
  #   col1: memory / swap / zram bars
  #   col2: PSI pressure bars (CPU / mem / IO) — the same files at
  #         /proc/pressure/* we drill into via /tmp/psi-breakdown.py
  #   col3: disk + network IO + task counts + uptime + battery
  #
  # Apply: ba_flakes_desktop/build.sh switch  (any open htop picks
  # up the new config on next launch — Ctrl+C + restart htop).
  xdg.configFile."htop/htoprc".text = ''
    # GENERATED BY home-manager — DO NOT EDIT (htop won't be able to
    # write back to /nix/store — that's intentional, keeps it pinned).
    htop_version=3.3.0
    config_reader_min_version=3
    fields=0 48 17 18 38 39 40 2 46 47 49 1
    hide_kernel_threads=1
    hide_userland_threads=0
    hide_running_in_container=0
    shadow_other_users=0
    show_thread_names=0
    show_program_path=1
    highlight_base_name=1
    highlight_deleted_exe=1
    shadow_distribution_path_prefix=0
    highlight_megabytes=1
    highlight_threads=1
    highlight_changes=1
    highlight_changes_delay_secs=5
    find_comm_in_cmdline=1
    strip_exe_from_cmdline=1
    show_merged_command=0
    header_margin=1
    screen_tabs=1
    detailed_cpu_time=1
    cpu_count_from_one=0
    show_cpu_usage=1
    show_cpu_frequency=1
    show_cpu_temperature=1
    degree_fahrenheit=0
    update_process_names=0
    account_guest_in_cpu_meter=0
    color_scheme=0
    enable_mouse=1
    delay=15
    hide_function_bar=0
    header_layout=four
    # col 0 — ALL 8 CORES as individual stacked bars (mode 1 = Bar). With
    # detailed_cpu_time=1 each bar splits into colors:
    #   blue   = user (low priority)         green = user (normal nice)
    #   red    = kernel/system               yellow = irq    magenta = soft-irq
    #   grey   = iowait                      cyan   = steal/guest
    # So a "red+grey" core = doing kernel work + waiting on disk → exactly
    # the green-vs-red-vs-IO visibility you want. NOT AllCPUs2 (that
    # collapses two cores per row); plain AllCPUs gives one bar per core.
    column_meters_0=AllCPUs
    column_meter_modes_0=1
    # col 1 — memory hierarchy bars
    column_meters_1=Memory Swap ZRAM
    column_meter_modes_1=1 1 1
    # col 2 — PSI pressure bars (the same /proc/pressure/* files visible
    # at all times — pinpoints stalls without leaving htop)
    column_meters_2=Pressure_CPU Pressure_Memory Pressure_IO
    column_meter_modes_2=1 1 1
    # col 3 — text counters (compact, dense)
    column_meters_3=LoadAverage Tasks Uptime DiskIO NetworkIO Battery ClocksSource
    column_meter_modes_3=2 2 2 2 2 2 2
    tree_view=0
    sort_key=46
    tree_sort_key=0
    sort_direction=-1
    tree_sort_direction=1
    tree_view_always_by_pid=0
    all_branches_collapsed=0
    # MAIN tab — full forensics, every signal in one row:
    # process basics + memory + state + %CPU/%MEM + per-process PSI delays
    # (CPU stall %, IO stall %, swap stall %) + page faults major/minor +
    # context switches + threads + IO rates. Use h/j/k/l or arrow keys to
    # scroll horizontally if it overflows your terminal width.
    screen:MAIN=PID USER PRIORITY NICE NLWP M_VIRT M_RESIDENT M_SHARE M_PSS M_SWAP STATE PERCENT_CPU PERCENT_MEM PERCENT_CPU_DELAY PERCENT_IO_DELAY PERCENT_SWAP_DELAY MAJFLT MINFLT IO_RATE PERCENT_GPU TIME Command
    .sort_key=PERCENT_CPU
    .tree_sort_key=PID
    .tree_view_always_by_pid=0
    .tree_view=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
    screen:CPU=PID USER PRIORITY NICE NLWP PERCENT_CPU PERCENT_NORM_CPU MAJFLT MINFLT STATE TIME Command
    .sort_key=PERCENT_CPU
    .tree_sort_key=PID
    .tree_view_always_by_pid=0
    .tree_view=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
    screen:MEMORY=PID USER M_VIRT M_RESIDENT M_SHARE M_PSS M_SWAP M_PSSWP PERCENT_MEM Command
    .sort_key=M_RESIDENT
    .tree_sort_key=PID
    .tree_view_always_by_pid=0
    .tree_view=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
    screen:DISK=PID USER IO_PRIORITY IO_RATE IO_READ_RATE IO_WRITE_RATE PERCENT_IO_DELAY PERCENT_CPU STATE Command
    .sort_key=IO_RATE
    .tree_sort_key=PID
    .tree_view_always_by_pid=0
    .tree_view=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
    screen:GPU=PID USER PERCENT_GPU GPU_TIME PERCENT_CPU PERCENT_MEM M_RESIDENT STATE Command
    .sort_key=PERCENT_GPU
    .tree_sort_key=PID
    .tree_view_always_by_pid=0
    .tree_view=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
  '';

  # ─────────────────────────────────────────────────────────────────
  # Custom plasmoid — org.kde.plasma.kstats (system monitor widget)
  # ─────────────────────────────────────────────────────────────────
  # Vendored into the flake (../dotfiles/kde/plasmoids/) so the widget is
  # declaratively owned, not a hand-installed dir under ~/.local. Deployed
  # via a real `cp`, NOT xdg.dataFile/home.file symlinks: KDE 6's KPackage
  # loader resolves each file's realpath and rejects the package if that
  # resolves outside the package directory ("kf.package: Path traversal
  # attempt detected: ...is not inside .../plasmoids/org.kde.plasma.kstats/")
  # — which is exactly what a symlink into /nix/store does. Copying real
  # files keeps their realpath inside $HOME, satisfying that check, while
  # the flake path (a Nix store path, immutable + content-addressed) stays
  # the single source of truth. Re-copied on every switch (rm -rf first) so
  # stale content can never linger.
  home.activation.installKstatsPlasmoid = lib.hm.dag.entryAfter [ "writeBoundary" "configure-plasma" ] ''
    DEST="$HOME/.local/share/plasma/plasmoids/org.kde.plasma.kstats"
    rm -rf "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -r --no-preserve=mode,ownership "${../dotfiles/kde/plasmoids/org.kde.plasma.kstats}" "$DEST"
    chmod -R u+w "$DEST"
  '';

  # Autostart - Runs every login
  # Generated by ./session-template.nix from ./session-template.json.
  # See that JSON to add/remove apps and change their per-desktop layout.

  # Fix system tray showAllItems (plasma-manager writes to applet, but Plasma reads from containment)
  # DISABLED: The kquitapp6/kstart plasmashell combo causes GUI freezes 8 seconds after every login.
  # The activation script (fixSystemTray) handles this during home-manager switch instead.
  # If you need to fix system tray visibility, run manually:
  #   kquitapp6 plasmashell && kstart plasmashell
  #
  # xdg.configFile."autostart/fix-systray-showall.desktop".text = ''
  #   [Desktop Entry]
  #   Type=Application
  #   Name=Fix System Tray ShowAll
  #   Exec=sh -c 'sleep 8; CONFIG="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"; ...'
  #   X-KDE-autostart-phase=2
  #   OnlyShowIn=KDE;
  # '';
}
