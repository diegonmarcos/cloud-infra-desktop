# Cloud & Infrastructure Control Panel — system-tray icon (yad) + dark konsole
# windows. All items are data-driven from cloud-cp.json.
#
#   cloud-systray              -> tray icon + menu (auto-starts in session).
#
# Item types supported:
#   shell        -> bash -lc <arg> in held dark konsole
#   build-system -> build.sh <arg> in system flake (via nixos-switch-gui)
#   build-desktop-> build.sh <arg> in desktop flake konsole
#   log-system   -> tail newest system build log
#   log-desktop  -> tail newest desktop build log
#   xdg          -> xdg-open <arg>
{ config, lib, pkgs, ... }:

let
  flakeSys  = "/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos";
  flakeDsk  = "/home/diego/git/unix/ba_flakes_desktop";
  flakeCloud= "/home/diego/git/cloud";
  konsole   = "/run/current-system/sw/bin/konsole";

  wd = builtins.fromJSON (builtins.readFile ./cloud-cp.json);

  subst = s: lib.replaceStrings
    [ "{FLAKE_SYSTEM}" "{FLAKE_DESKTOP}" "{FLAKE_CLOUD}" "{FLAKE}" ]
    [ flakeSys         flakeDsk          flakeCloud       flakeSys  ] s;

  items = lib.concatMap (s: s.items) wd.sections;

  mkAction = it:
    let arg = subst (it.arg or ""); in
    if it.type == "shell" then
      ''exec ${konsole} --hold --separate -p ColorScheme=Breeze \
          --title "Cloud" \
          -e ${pkgs.bash}/bin/bash -lc ${lib.escapeShellArg "${arg}; printf '\\n=== done (exit %s) — close ===\\n' \"$?\""}''
    else if it.type == "build-system" then
      ''exec ${konsole} --hold --separate -p ColorScheme=Breeze \
          -p TerminalColumns=150 -p TerminalRows=48 --title "NixOS (system) — ${arg}" \
          -e ${pkgs.bash}/bin/bash -lc \
            ${lib.escapeShellArg "cd '${flakeSys}' && PATH=/run/wrappers/bin:$PATH ./build.sh '${arg}'; printf '\\n=== finished (exit %s) ===\\n' \"$?\""}''
    else if it.type == "build-desktop" then
      ''exec ${konsole} --hold --separate -p ColorScheme=Breeze \
          -p TerminalColumns=150 -p TerminalRows=48 --title "NixOS (desktop) — ${arg}" \
          -e ${pkgs.bash}/bin/bash -lc \
            ${lib.escapeShellArg "cd '${flakeDsk}' && PATH=/run/wrappers/bin:$PATH ./build.sh '${arg}'; printf '\\n=== finished (exit %s) ===\\n' \"$?\""}''
    else if it.type == "log-system" then
      ''exec ${konsole} --hold --separate -p ColorScheme=Breeze --title "System build log" \
          -e ${pkgs.bash}/bin/bash -lc \
            ${lib.escapeShellArg "f=$(ls -t '${flakeSys}'/logs/build-*.log 2>/dev/null | head -1); [ -n \"$f\" ] && tail -n 400 -f \"$f\" || echo 'no build logs yet'"}''
    else if it.type == "log-desktop" then
      ''exec ${konsole} --hold --separate -p ColorScheme=Breeze --title "Desktop build log" \
          -e ${pkgs.bash}/bin/bash -lc \
            ${lib.escapeShellArg "f=$(ls -t '${flakeDsk}'/logs/build-*.log 2>/dev/null | head -1); [ -n \"$f\" ] && tail -n 400 -f \"$f\" || echo 'no build logs yet'"}''
    else
      ''exec ${pkgs.xdg-utils}/bin/xdg-open ${lib.escapeShellArg arg}'';

  dispatch = lib.concatStringsSep "\n"
    (lib.imap0 (i: it: "      ${toString i}) ${mkAction it} ;;") items);

  menuStr = lib.concatStringsSep "|"
    (lib.imap0 (i: it: "${it.label}!cloud-systray --run-index ${toString i}!${it.icon or ""}") items);

  cloud-systray = pkgs.writeShellScriptBin "cloud-systray" ''
    if [ "''${1:-}" = "--run-index" ]; then
      case "''${2:-}" in
${dispatch}
        *) echo "bad index" >&2; exit 1 ;;
      esac
    fi
    # yad --notification uses GTK/AppIndicator which requires X11 (XWayland on Wayland)
    _rt="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -z "''${DISPLAY:-}" ]; then
      for _n in 0 1 2; do
        [ -S "/tmp/.X11-unix/X''${_n}" ] && export DISPLAY=":''${_n}" && break
      done
    fi
    if [ -z "''${XAUTHORITY:-}" ]; then
      for _f in "''$_rt"/xauth_*; do
        [ -f "''$_f" ] && export XAUTHORITY="''$_f" && break
      done
    fi
    export GDK_BACKEND=x11
    export NO_AT_BRIDGE=1
    exec ${pkgs.yad}/bin/yad --notification \
      --image="${wd.tray_icon or "network-vpn"}" \
      --text="${wd.tray_tooltip or "Cloud & Infra"}" \
      --menu="${menuStr}" \
      --command="true"
  '';

  cpItem = pkgs.makeDesktopItem {
    name = "cloud-systray";
    desktopName = "Cloud & Infra Control Panel";
    comment = "Monitor VMs, services, mesh, and flake builds";
    exec = "${cloud-systray}/bin/cloud-systray";
    icon = "network-vpn";
    categories = [ "System" "Network" ];
    terminal = false;
    startupNotify = false;
  };

in {
  environment.systemPackages = [ cloud-systray cpItem ];

  systemd.user.services.cloud-systray = {
    description = "Cloud & Infra Control Panel tray icon";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${cloud-systray}/bin/cloud-systray";
      Environment = [
        "DISPLAY=:0"
        "GDK_BACKEND=x11"
        "XDG_RUNTIME_DIR=/run/user/1000"
        "XDG_CURRENT_DESKTOP=KDE"
        "NO_AT_BRIDGE=1"
      ];
      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
