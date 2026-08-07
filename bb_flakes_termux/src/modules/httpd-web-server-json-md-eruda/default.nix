# httpd-web-server-json-md-eruda (Termux) — file server with Markdown,
# JSON/YAML table, and Eruda DevTools rendering.
#
# Fetches the same prebuilt aarch64 Node SEA binary the desktop module fetches
# (published by 1_workflows/src/cicd/ship-httpd-web-server-json-md-eruda.yml
# to the rolling httpd-web-server-json-md-eruda-latest GitHub Release) — same
# fetchurl + hashes.json pattern as da_my-ai (see
# bb_flakes_termux/src/pkgs/my-ai-hashes.json). No more loose .mjs + lib
# assets shipped via home.file.
#
# Provides: httpd-web-server-json-md-eruda command (start|stop|status|restart),
# PID-file wrapper style copied from ../cloud-ide-sshd/default.nix (the only
# existing Termux daemon pattern in this repo).
#
# Also wires a REAL background service via runit (termux-services), since
# previously this tool only ran on-demand from an interactive shell. This is
# genuinely new infra for the repo — scoped narrowly to this one service, not
# a general runit/termux-services framework:
#   - requires `pkg install termux-services` on the underlying Termux
#     install (termux-services + runit live in Termux's own $PREFIX, managed
#     by its `pkg`/apt, NOT the nix store — nix-on-droid coexists with that
#     prefix rather than rebuilding it) — home.activation below only calls
#     `sv-enable` best-effort and warns (does not fail activation) if it's
#     missing.
#   - $HOME/.termux/service/httpd-web-server-json-md-eruda/run execs the
#     fetched binary directly (no fork), per runit convention: runsv restarts
#     it automatically on exit, giving real supervision the on-demand
#     PID-file wrapper never had.
{ config, pkgs, lib, ... }:

let
  hashes  = builtins.fromJSON (builtins.readFile ./hashes.json);
  baseUrl = "https://github.com/diegonmarcos/unix/releases/download/httpd-web-server-json-md-eruda-latest";

  httpdBin = pkgs.fetchurl {
    url  = "${baseUrl}/httpd-web-server-json-md-eruda-aarch64";
    hash = hashes.httpd-web-server-json-md-eruda;
  };

  serviceName = "httpd-web-server-json-md-eruda";

  httpdWrapperScript = pkgs.writeShellScript "httpd-web-server-json-md-eruda" ''
    # httpd-web-server-json-md-eruda — POSIX wrapper for the fetched SEA binary
    # Usage: httpd-web-server-json-md-eruda [start|stop|status|restart] [port] [dir]
    #
    # This wrapper is the on-demand / interactive-shell path (fish auto-start).
    # The runit service (sv httpd-web-server-json-md-eruda) is the real
    # background-supervision path — see run script below. Both exec the same
    # fetched binary; running both at once will fight over the port exactly
    # like the old http-dev wrapper + disabled systemd unit did on desktop.

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

  # runit run script — `exec`'d, NOT forked, per runit convention: runsv is
  # the supervisor and needs to remain PID 1 of this service's process group.
  # Fixed port 8000 / $HOME root, matching the wrapper's defaults — the
  # runit service is meant to always-serve-$HOME-on-8000; use the wrapper
  # directly for one-off custom roots/ports.
  runitRunScript = pkgs.writeShellScript "httpd-web-server-json-md-eruda-run" ''
    exec "${httpdBin}" 8000 "$HOME"
  '';
in
{
  home.file.".local/bin/httpd-web-server-json-md-eruda" = {
    source = httpdWrapperScript;
    executable = true;
  };

  home.file.".termux/service/${serviceName}/run" = {
    source = runitRunScript;
    executable = true;
  };

  # Enable the runit service every activation (idempotent — sv-enable is a
  # no-op symlink-create if already enabled). Best-effort: warns rather than
  # fails if termux-services isn't installed on the underlying Termux prefix,
  # since nix-on-droid doesn't own that install.
  home.activation.httpdWebServerJsonMdErudaSvEnable = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if command -v sv-enable >/dev/null 2>&1; then
      $DRY_RUN_CMD sv-enable ${serviceName} 2>/dev/null || \
        echo "[${serviceName}] WARNING: sv-enable failed — check 'pkg install termux-services' and runsvdir status"
    else
      echo "[${serviceName}] WARNING: sv-enable not found — run 'pkg install termux-services' on Termux for real background supervision (falling back to on-demand wrapper only)"
    fi
  '';
}
