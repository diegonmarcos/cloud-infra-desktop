# programs/watchdog-systray.nix — KDE system-tray applets for the system-
# protection stack (2026-07-10, user request). Two SNI trays via yad:
#   • Watchdog — live PSI/slice status, a MANUAL OOM trigger (same action as
#     the Alt+SysRq+F kernel keybind), the keybind reminder, and a log viewer.
#   • NixOS — quick switch/generations from the tray.
# All labels/commands/units are data-driven from watchdog-systray.json.
# Always-on user services (like programs/dev-shell.nix). yad SNI items appear
# in the Plasma tray automatically.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./watchdog-systray.json);
  wt  = cfg.watchdog_tray;
  nt  = cfg.nixos_tray;
  logUnits    = lib.concatStringsSep " " wt.log_units;
  statusSlices = lib.concatStringsSep " " wt.status_slices;
in {
  home.packages = [ pkgs.yad ];

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
      AVOID="kwin|plasmashell|sddm|Xwayland|pipewire|wireplumber|systemd|dbus|sshd|watchdog-|yad"
      line=$(ps -eo pid=,rss=,comm= --sort=-rss | grep -Ev -- "$AVOID" | awk '$1>1{print;exit}')
      pid=$(echo "$line" | awk '{print $1}'); comm=$(echo "$line" | awk '{print $3}')
      [ -n "$pid" ] && { kill -9 "$pid" 2>/dev/null; command -v notify-send >/dev/null 2>&1 && notify-send -u critical "Watchdog OOM" "Killed biggest hog: $comm (pid $pid)"; }
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

  # ── Watchdog SNI tray ───────────────────────────────────────────────────
  home.file.".local/bin/watchdog-systray" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/watchdog-systray.nix.
      exec yad --notification --listen --no-middle \
        --image="${wt.icon}" --text="${wt.title}" \
        --command="bash -lc watchdog-status" \
        --menu="Status / PSI!bash -lc watchdog-status!security-high|🔴 Trigger OOM (${wt.oom.keybind_primary})!bash -lc watchdog-oom!process-stop|Watch guard logs!bash -lc watchdog-logs!utilities-log-viewer|Quit!quit!application-exit"
    '';
  };

  # ── NixOS SNI tray ──────────────────────────────────────────────────────
  home.file.".local/bin/nixos-systray" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/watchdog-systray.nix.
      B="${nt.build_sh}"
      exec yad --notification --listen --no-middle \
        --image="${nt.icon}" --text="${nt.title}" \
        --command="konsole --hold -e bash -lc '$B status'" \
        --menu="Switch (pull latest, isolated)!konsole --hold -e bash -lc '$B switch'!system-software-update|Generations!konsole --hold -e bash -lc 'home-manager generations; read'!document-multiple|Status!konsole --hold -e bash -lc '$B status; read'!dialog-information|Quit!quit!application-exit"
    '';
  };

  systemd.user.services.watchdog-systray = lib.mkIf wt.enable {
    Unit = { Description = "Watchdog system-protection tray"; After = [ "graphical-session.target" ]; PartOf = [ "graphical-session.target" ]; };
    Service = { ExecStart = "%h/.local/bin/watchdog-systray"; Restart = "on-failure"; RestartSec = 5; };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.nixos-systray = lib.mkIf nt.enable {
    Unit = { Description = "NixOS tray"; After = [ "graphical-session.target" ]; PartOf = [ "graphical-session.target" ]; };
    Service = { ExecStart = "%h/.local/bin/nixos-systray"; Restart = "on-failure"; RestartSec = 5; };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
