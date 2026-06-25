# NixOS Control Panel — system-tray icon (yad) + dark verbose progress windows
# (konsole). Both tools are PREBUILT in the binary cache — no source compile.
#
#   nixos-switch-gui <cmd>  -> run `build.sh <cmd>` in a held, dark, verbose
#                              konsole (real TTY so sudo can prompt in-window).
#   nixos-systray           -> the tray icon + menu (auto-starts in session).
#
# Menu is data-driven (nixos-cp.json) and baked into the dispatch at build time.
{ config, lib, pkgs, ... }:

let
  flakeDir = "/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos";
  konsole  = "/run/current-system/sw/bin/konsole";
  wd       = builtins.fromJSON (builtins.readFile ./nixos-cp.json);
  items    = lib.concatMap (s: s.items) wd.sections;
  subst    = s: lib.replaceStrings [ "{FLAKE}" ] [ flakeDir ] s;

  # verbose dark konsole running one build.sh command
  nixos-switch-gui = pkgs.writeShellScriptBin "nixos-switch-gui" ''
    CMD="''${1:-switch}"
    exec ${konsole} --hold --separate -p ColorScheme=Breeze \
      -p TerminalColumns=150 -p TerminalRows=48 --title "NixOS — $CMD" \
      -e ${pkgs.bash}/bin/bash -lc \
        "cd '${flakeDir}' && PATH=/run/wrappers/bin:\$PATH ./build.sh '$CMD'; printf '\n========== finished (exit %s) — close this window ==========\n' \"\$?\""
  '';

  # one click-action per menu item (baked from the JSON)
  mkAction = it:
    let arg = subst (it.arg or ""); in
    if it.type == "build" then ''exec ${nixos-switch-gui}/bin/nixos-switch-gui ${lib.escapeShellArg arg}''
    else if it.type == "shell" then ''exec ${konsole} --hold --separate -p ColorScheme=Breeze --title "NixOS" -e ${pkgs.bash}/bin/bash -lc ${lib.escapeShellArg "${arg}; printf '\\n=== done (exit %s) — close ===\\n' \"$?\""}''
    else if it.type == "log" then ''exec ${konsole} --hold --separate -p ColorScheme=Breeze --title "NixOS build log" -e ${pkgs.bash}/bin/bash -lc ${lib.escapeShellArg "f=$(ls -t '${flakeDir}'/logs/build-*.log 2>/dev/null | head -1); if [ -n \"$f\" ]; then tail -n 400 -f \"$f\"; else echo 'no build logs yet'; fi"}''
    else ''exec ${pkgs.xdg-utils}/bin/xdg-open ${lib.escapeShellArg arg}'';

  dispatch = lib.concatStringsSep "\n"
    (lib.imap0 (i: it: "      ${toString i}) ${mkAction it} ;;") items);

  # yad menu string: "label!nixos-systray --run-index N!icon|..."
  menuStr = lib.concatStringsSep "|"
    (lib.imap0 (i: it: "${it.label}!nixos-systray --run-index ${toString i}!${it.icon or ""}") items);

  nixos-systray = pkgs.writeShellScriptBin "nixos-systray" ''
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
      --image="${wd.tray_icon or "nix-snowflake"}" \
      --text="${wd.tray_tooltip or "NixOS"}" \
      --menu="${menuStr}" \
      --command="true"
  '';

  cpItem = pkgs.makeDesktopItem {
    name = "nixos-systray";
    desktopName = "NixOS Control Panel";
    comment = "Rebuild & manage NixOS — switch, dry-run, update, logs, settings";
    exec = "${nixos-systray}/bin/nixos-systray";
    icon = "nix-snowflake";
    categories = [ "System" ];
    terminal = false;
    startupNotify = false;
  };

in {
  environment.systemPackages = [ nixos-switch-gui nixos-systray cpItem pkgs.yad ];

  systemd.user.services.nixos-systray = {
    description = "NixOS Control Panel tray icon";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      # Wait for Plasma's StatusNotifierWatcher to register on D-Bus before yad
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${nixos-systray}/bin/nixos-systray";
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
