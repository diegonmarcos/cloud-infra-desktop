# NixOS desktop control panel — a system-tray icon (yad) with a data-driven menu
# of NixOS operations, each opening a DARK, full-verbose konsole window.
#
#   nixos-switch-gui [switch|boot|test|dry-run|update|…]  -> one op in a held,
#                                                            dark konsole window.
#   nixos-cp                                              -> the tray icon + menu
#                                                            (auto-started in the
#                                                            graphical session).
#   nixos-cp --run-index N                                -> run menu item N.
#
# Menu is data-driven (nixos-cp.json) — add/reorder entries there, no script
# edit. konsole gives a real TTY so `sudo nixos-rebuild` can prompt in-window.
{ config, lib, pkgs, ... }:

let
  flakeDir = "/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos";
  konsole = "/run/current-system/sw/bin/konsole";   # system-installed (Plasma)
  menuJson = ./nixos-cp.json;

  # JS helper kept OUT of the shell/nix strings (uses only "double quotes" so it
  # never collides with Nix's '' string terminator). modes: menu | field | tray.
  menuHelper = pkgs.writeText "nixos-cp-menu.js" ''
    const c = require(process.argv[2]);
    const mode = process.argv[3];
    if (mode === "menu") {
      const out = c.items.map((it, i) =>
        it.type === "sep"
          ? (it.label || "-") + "!!"
          : it.label + "!nixos-cp --run-index " + i + "!" + (it.icon || ""));
      process.stdout.write(out.join("|"));
    } else if (mode === "field") {
      const it = c.items[parseInt(process.argv[4], 10)] || {};
      process.stdout.write(String(it[process.argv[5]] || ""));
    } else if (mode === "tray") {
      process.stdout.write(String(c[process.argv[4]] || ""));
    }
  '';

  # ── one NixOS op in a dark, held, verbose konsole ─────────────────────────
  nixos-switch-gui = pkgs.writeShellApplication {
    name = "nixos-switch-gui";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      CMD="''${1:-switch}"
      exec ${konsole} --hold --separate \
        -p ColorScheme=Breeze \
        -p TerminalColumns=150 -p TerminalRows=48 \
        --title "NixOS rebuild — $CMD" \
        -e ${pkgs.bash}/bin/bash -lc \
          "cd '${flakeDir}' && PATH=/run/wrappers/bin:\$PATH ./build.sh '$CMD'; printf '\n========== finished (exit %s) — close this window ==========\n' \"\$?\""
    '';
  };

  # ── tray icon + menu (yad), dispatches menu items by index ────────────────
  nixos-cp = pkgs.writeShellApplication {
    name = "nixos-cp";
    runtimeInputs = [ pkgs.yad pkgs.nodejs_22 pkgs.coreutils pkgs.xdg-utils nixos-switch-gui ];
    text = ''
      CONF=${menuJson}
      H=${menuHelper}
      FLAKE='${flakeDir}'

      if [ "''${1:-}" = "--run-index" ]; then
        idx="''${2:?index}"
        type="$(node "$H" "$CONF" field "$idx" type)"
        arg="$(node "$H" "$CONF" field "$idx" arg)"
        arg="''${arg//\{FLAKE\}/$FLAKE}"
        case "$type" in
          build) exec nixos-switch-gui "$arg" ;;
          shell) exec ${konsole} --hold --separate -p ColorScheme=Breeze --title "NixOS" -e ${pkgs.bash}/bin/bash -lc "$arg; printf '\n=== done (exit %s) — close ===\n' \"\$?\"" ;;
          log)   exec ${konsole} --hold --separate -p ColorScheme=Breeze --title "NixOS build log" -e ${pkgs.bash}/bin/bash -lc "f=\$(ls -t '$FLAKE'/logs/build-*.log 2>/dev/null | head -1); if [ -n \"\$f\" ]; then tail -n 400 -f \"\$f\"; else echo 'no build logs yet'; fi" ;;
          open)  exec xdg-open "$arg" ;;
          *) echo "unknown action type: $type" >&2; exit 1 ;;
        esac
      fi

      icon="$(node "$H" "$CONF" tray tray_icon)"
      tip="$(node "$H" "$CONF" tray tray_tooltip)"
      menu="$(node "$H" "$CONF" menu)"
      exec yad --notification \
        --image="$icon" \
        --text="$tip" \
        --menu="$menu" \
        --command="true"
    '';
  };

  rebuildItem = pkgs.makeDesktopItem {
    name = "nixos-switch-gui";
    desktopName = "NixOS Rebuild";
    comment = "Rebuild & switch (verbose, dark window)";
    exec = "${nixos-switch-gui}/bin/nixos-switch-gui switch";
    icon = "nix-snowflake";
    categories = [ "System" ];
    terminal = false;
  };
  cpItem = pkgs.makeDesktopItem {
    name = "nixos-cp";
    desktopName = "NixOS Control Panel";
    comment = "NixOS tray: switch, dry-run, update, logs, settings…";
    exec = "${nixos-cp}/bin/nixos-cp";
    icon = "nix-snowflake";
    categories = [ "System" ];
    terminal = false;
  };

in {
  environment.systemPackages = [ nixos-switch-gui nixos-cp rebuildItem cpItem ];

  # Tray icon auto-starts in the graphical session and respawns if it dies.
  systemd.user.services.nixos-cp-tray = {
    description = "NixOS control-panel tray icon";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${nixos-cp}/bin/nixos-cp";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
