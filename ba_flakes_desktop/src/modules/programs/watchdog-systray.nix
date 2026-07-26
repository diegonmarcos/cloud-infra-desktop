# System-protection stack (2026-07-10, user request; Wayland SNI 2026-07-26). Two
# StatusNotifierItem trays via python3+AyatanaAppIndicator3 (native on Plasma 6 Wayland,
# unlike the old yad --notification/GtkStatusIcon X11 path):
#   • Watchdog — live PSI/slice status, a MANUAL OOM trigger (same action as
#     Alt+SysRq+F), and a log-follow shortcut.
#   • NixOS — quick switch/generations from the tray.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./watchdog-systray.json);
  wt  = cfg.watchdog_tray;
  nt  = cfg.nixos_tray;
  logUnits    = lib.concatStringsSep " " wt.log_units;
  statusSlices = lib.concatStringsSep " " wt.status_slices;

  # Substitute {{keybind_primary}} etc. placeholders in JSON menu labels.
  expandLabel = label: lib.replaceStrings [ "{{keybind_primary}}" "{{keybind_convenience}}" ]
    [ wt.oom.keybind_primary wt.oom.keybind_convenience ] label;

  # Render one tray's `menu` (list of {label,icon,command}) as a Python list-of-tuples
  # literal, fully data-driven from the JSON — no item is ever hardcoded in the script.
  # AppIndicator/SNI trays have no separate "primary click" action (left-click always
  # opens the menu), so `defaultCmd` is folded in as the first entry when it isn't
  # already one of the configured menu commands, preserving the old yad --command behavior.
  pyMenu = { icon, defaultCmd, menu }:
    let
      items = (lib.optional (! builtins.elem defaultCmd (map (m: m.command) menu))
        { label = "▶ Open"; inherit icon; command = defaultCmd; }) ++ menu;
    in lib.concatMapStringsSep ",\n    " (item:
      "(${builtins.toJSON (expandLabel item.label)}, ${builtins.toJSON item.icon}, ${builtins.toJSON item.command})"
    ) items;

  # Shared SNI tray body (Wayland-native, DBus StatusNotifierItem via libayatana-appindicator).
  # id/icon/title/defaultCmd/menu are the only per-tray inputs — no tray-specific logic here.
  sniScript = { id, icon, title, defaultCmd, menu }: ''
    #!/usr/bin/env python3
    # Generated from programs/watchdog-systray.nix. Wayland-native SNI tray (no DISPLAY/X11).
    import subprocess
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import Gtk, AyatanaAppIndicator3 as AppIndicator3

    MENU = [
      ${pyMenu { inherit icon defaultCmd menu; }}
    ]

    def run_cmd(_widget, cmd):
        subprocess.Popen(["/bin/sh", "-c", cmd])

    def build_menu():
        menu = Gtk.Menu()
        for label, icon_name, cmd in MENU:
            item = Gtk.ImageMenuItem.new_with_label(label)
            if icon_name:
                item.set_image(Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.MENU))
                item.set_always_show_image(True)
            item.connect("activate", run_cmd, cmd)
            menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        menu.append(quit_item)
        menu.show_all()
        return menu

    indicator = AppIndicator3.Indicator.new(
        ${builtins.toJSON id}, ${builtins.toJSON icon},
        AppIndicator3.IndicatorCategory.SYSTEM_SERVICES,
    )
    indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
    indicator.set_title(${builtins.toJSON title})
    indicator.set_menu(build_menu())

    Gtk.main()
  '';
in {
  home.packages = [
    pkgs.yad # still used by watchdog-status's --text-info dialog (a plain window, not a tray icon — works fine under Wayland/XWayland)
    (pkgs.python3.withPackages (ps: [ ps.pygobject3 ]))
    pkgs.libayatana-appindicator
    pkgs.gtk3
  ];

  # ── OOM trigger — the manual "kill the runaway NOW" button ──────────────
  # kernel_sysrq=true → in-kernel SysRq OOM (echo f > /proc/sysrq-trigger),
  # the exact action of Alt+SysRq+F, works even under heavy load. NOPASSWD
  # sudo (this host) means no GUI password prompt. Falls back to killing the
  # biggest non-essential RSS process if sysrq is off.
  home.file.".local/bin/watchdog-oom" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/watchdog-systray.nix.
      set -uo pipefail
      _sudo="/run/wrappers/bin/sudo"; [ -x "$_sudo" ] || _sudo="sudo"
      if ${if wt.oom.kernel_sysrq then "true" else "false"} && [ -w /proc/sysrq-trigger -o -n "$($_sudo -n true 2>/dev/null; echo ok)" ]; then
        command -v notify-send >/dev/null 2>&1 && notify-send -u critical -i security-high "Watchdog OOM" "Triggering kernel OOM-killer (SysRq f) — killing the biggest memory hog." || true
        echo f | $_sudo tee /proc/sysrq-trigger >/dev/null 2>&1 && exit 0
      fi
      # Fallback: kill the biggest non-essential RSS process ourselves.
      pid=$(ps -eo pid,rss,comm --sort=-rss | awk 'NR>1 && $3!~/systemd|Xorg|kwin|plasma/{print $1; exit}')
      [ -n "$pid" ] && kill -9 "$pid"
    '';
  };

  # ── Live status dialog — PSI + slice caps + killer states ───────────────
  home.file.".local/bin/watchdog-status" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/watchdog-systray.nix.
      set -uo pipefail
      out="System-protection status  ($(date +%H:%M:%S))\n\n"
      out+="── Killers ──\n"
      for u in ${logUnits}; do
        out+="$(printf '%-26s %s' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo '?')")\n"
      done
      out+="\n── Pressure (full avg10) / slice ──\n"
      for s in ${statusSlices}; do
        cg="/sys/fs/cgroup/$s"
        io=$(awk '/full/{for(i=1;i<=NF;i++)if($i~/^avg10=/){sub(/avg10=/,"",$i);print $i}}' "$cg/io.pressure" 2>/dev/null)
        me=$(awk '/full/{for(i=1;i<=NF;i++)if($i~/^avg10=/){sub(/avg10=/,"",$i);print $i}}' "$cg/memory.pressure" 2>/dev/null)
        out+="$(printf '%-30s io=%-6s mem=%-6s' "$s" "''${io:-0}" "''${me:-0}")\n"
      done
      out+="\n── RAM ──\n$(free -h | awk '/Mem|Swap/{printf "%-6s used %-6s free %-6s\n",$1,$3,$4}')\n"
      out+="\nOOM keybind: ${wt.oom.keybind_primary} (kernel, always works) · ${wt.oom.keybind_convenience} (KDE)\n"
      echo -e "$out" | yad --title="${wt.title}" --text-info --width=560 --height=440 \
        --button="Trigger OOM now!process-stop:bash -lc watchdog-oom" \
        --button="Watch logs:bash -lc watchdog-logs" --button="Close:0" 2>/dev/null || true
    '';
  };

  # ── Log viewer — follow every killer's journal ──────────────────────────
  home.file.".local/bin/watchdog-logs" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/watchdog-systray.nix.
      _u=""; for u in ${logUnits}; do _u="$_u -u $u"; done
      exec konsole --hold -p tabtitle="Watchdog logs" -e bash -c "journalctl -f $_u" 2>/dev/null
    '';
  };

  # ── Watchdog SNI tray (Wayland-native) ───────────────────────────────────
  home.file.".local/bin/watchdog-systray" = {
    executable = true;
    text = sniScript {
      id = "watchdog-systray";
      icon = wt.icon;
      title = wt.title;
      defaultCmd = wt.default_command;
      menu = wt.menu;
    };
  };

  # ── NixOS SNI tray (Wayland-native) ──────────────────────────────────────
  home.file.".local/bin/nixos-systray" = {
    executable = true;
    text = sniScript {
      id = "nixos-systray";
      icon = nt.icon;
      title = nt.title;
      defaultCmd = nt.default_command;
      menu = nt.menu;
    };
  };

  systemd.user.services.watchdog-systray = lib.mkIf wt.enable {
    Unit = { Description = "Watchdog system-protection tray"; After = [ "graphical-session.target" ]; PartOf = [ "graphical-session.target" ]; };
    Service = { ExecStart = "%h/.local/bin/watchdog-systray"; Restart = "on-failure"; RestartSec = 5;
      Environment = [
        "GI_TYPELIB_PATH=${pkgs.libayatana-appindicator}/lib/girepository-1.0:${pkgs.gtk3}/lib/girepository-1.0"
        "LD_LIBRARY_PATH=${pkgs.libayatana-appindicator}/lib"
      ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.nixos-systray = lib.mkIf nt.enable {
    Unit = { Description = "NixOS tray"; After = [ "graphical-session.target" ]; PartOf = [ "graphical-session.target" ]; };
    Service = { ExecStart = "%h/.local/bin/nixos-systray"; Restart = "on-failure"; RestartSec = 5;
      Environment = [
        "GI_TYPELIB_PATH=${pkgs.libayatana-appindicator}/lib/girepository-1.0:${pkgs.gtk3}/lib/girepository-1.0"
        "LD_LIBRARY_PATH=${pkgs.libayatana-appindicator}/lib"
      ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
