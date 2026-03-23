# Web server with Markdown rendering + Eruda DevTools
# Provides: http-dev command (start|stop|status|restart)
# Wraps: web-server-md-eruda.mjs (Node.js file server)
{ config, pkgs, lib, ... }:

let
  httpDevScript = pkgs.writeShellScript "http-dev" ''
    #!/bin/sh
    # http-dev — POSIX wrapper for web-server-md-eruda.mjs
    # Usage: http-dev [start|stop|status|restart] [port] [dir]

    PORT="''${2:-8000}"
    DIR="''${3:-$HOME}"
    PID_FILE="$HOME/.cache/web-server-md-eruda.pid"
    SERVER="$HOME/.local/bin/web-server-md-eruda.mjs"

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
      node "$SERVER" "$PORT" "$DIR" >/dev/null 2>&1 &
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
      *)       echo "Usage: http-dev {start|stop|status|restart} [port] [dir]"; exit 1 ;;
    esac
  '';
in
{
  # Deploy the .mjs server + libs
  home.file.".local/bin/web-server-md-eruda.mjs".source = ./dotfiles/web-server-md-eruda.mjs;
  home.file.".local/lib/httpd/marked.min.js".source = ./dotfiles/httpd-lib/marked.min.js;
  home.file.".local/lib/httpd/github-markdown-dark.css".source = ./dotfiles/httpd-lib/github-markdown-dark.css;

  # Deploy the POSIX wrapper as http-dev
  home.file.".local/bin/http-dev" = {
    source = httpDevScript;
    executable = true;
  };
}
