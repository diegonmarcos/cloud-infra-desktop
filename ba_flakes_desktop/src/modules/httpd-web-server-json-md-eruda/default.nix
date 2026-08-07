# httpd-web-server-json-md-eruda — file server with Markdown, JSON/YAML
# table, and Eruda DevTools rendering.
# Provides: httpd-web-server-json-md-eruda command (start|stop|status|restart)
#
# Ships as a prebuilt, per-arch Node Single Executable Application binary
# fetched from the rolling GitHub Release (built + published by
# 1_workflows/src/cicd/ship-httpd-web-server-json-md-eruda.yml), NOT as loose
# source files interpreted by `node script.mjs` — same fetchurl + hashes.json
# pattern as da_my-ai/nix/my-ai.nix. Bump ./hashes.json only via that CI job's
# update-hashes step.
{ config, pkgs, lib, ... }:

let
  hashes  = builtins.fromJSON (builtins.readFile ./hashes.json);
  archMap = { "x86_64-linux" = "x86_64"; "aarch64-linux" = "aarch64"; };
  arch    = archMap.${pkgs.stdenv.hostPlatform.system}
              or (throw "httpd-web-server-json-md-eruda: unsupported platform ${pkgs.stdenv.hostPlatform.system}");
  baseUrl = "https://github.com/diegonmarcos/unix/releases/download/httpd-web-server-json-md-eruda-latest";
  sys     = hashes.${pkgs.stdenv.hostPlatform.system};

  httpdBin = pkgs.fetchurl {
    url  = "${baseUrl}/httpd-web-server-json-md-eruda-${arch}";
    hash = sys.httpd-web-server-json-md-eruda;
  };

  httpdWrapperScript = pkgs.writeShellScript "httpd-web-server-json-md-eruda" ''
    #!/bin/sh
    # httpd-web-server-json-md-eruda — POSIX wrapper for the fetched SEA binary
    # Usage: httpd-web-server-json-md-eruda [start|stop|status|restart] [port] [dir]

    PORT="''${2:-8000}"
    DIR="''${3:-$HOME}"
    PID_FILE="$HOME/.cache/httpd-web-server-json-md-eruda.pid"
    SERVER="${httpdBin}"

    is_running() {
      [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
    }

    do_start() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "$pid"
        return 0
      fi
      mkdir -p "$(dirname "$PID_FILE")"
      chmod +x "$SERVER" 2>/dev/null || true
      "$SERVER" "$PORT" "$DIR" >/dev/null 2>&1 &
      pid=$!
      echo "$pid" > "$PID_FILE"
      echo "$pid"
    }

    do_stop() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo "stopped (was PID $pid)"
      else
        rm -f "$PID_FILE"
        echo "not running"
      fi
    }

    do_status() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "running (PID $pid) on http://127.0.0.1:$PORT"
      else
        rm -f "$PID_FILE"
        echo "not running"
      fi
    }

    case "''${1:-start}" in
      start)   do_start ;;
      stop)    do_stop ;;
      status)  do_status ;;
      restart) do_stop; do_start ;;
      *)       echo "Usage: httpd-web-server-json-md-eruda {start|stop|status|restart} [port] [dir]"; exit 1 ;;
    esac
  '';
in
{
  # Deploy the POSIX wrapper as httpd-web-server-json-md-eruda. The fetched
  # binary itself is a nix store path (immutable, world-readable) — the
  # wrapper chmod +x's it defensively but fetchurl output is already 444.
  home.file.".local/bin/httpd-web-server-json-md-eruda" = {
    source = httpdWrapperScript;
    executable = true;
  };

  xdg.desktopEntries.httpd-web-server-json-md-eruda = {
    name = "httpd-web-server-json-md-eruda";
    comment = "Local file server — Markdown + JSON/YAML tables + Eruda DevTools";
    exec = "httpd-web-server-json-md-eruda restart 8000 %h";
    icon = "httpd-web-server-json-md-eruda";
    terminal = false;
    categories = [ "Network" "Utility" ];
  };

  # Systemd user service — start on login (not per-shell like termux)
  systemd.user.services.httpd-web-server-json-md-eruda = {
    Unit.Description = "httpd-web-server-json-md-eruda — file server (Markdown + JSON/YAML + Eruda)";
    Service = {
      ExecStart = "${httpdBin} 8000 %h";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
