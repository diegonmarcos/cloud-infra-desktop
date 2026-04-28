# Termux SSHD — declarative SSH daemon on port 8022 (dropbear-based)
#
# Why dropbear instead of OpenSSH:
#   OpenSSH's privsep uses fork+re-exec, which on Android/nix-on-droid fails
#   with "sshd re-exec requires execution with an absolute path" because
#   /proc/self/exe doesn't resolve correctly under Termux. Dropbear has no
#   privsep, was designed for embedded/limited systems, and runs cleanly here.
#
# Provides: termux-sshd command (start|stop|status|restart)
# Auto-starts via fish shellInit.
# Trusted pubkeys sourced from data/authorized-keys.json (data-driven).
{ config, pkgs, lib, ... }:

let
  authData = builtins.fromJSON (builtins.readFile ./data/authorized-keys.json);
  authorizedKeysContent =
    lib.concatStringsSep "\n" authData.trusted_pubkeys + "\n";

  # Absolute nix store paths — injected at flake-eval time so the wrapper
  # never depends on PATH resolution.
  dropbearBin    = "${pkgs.dropbear}/bin/dropbear";
  dropbearKeyBin = "${pkgs.dropbear}/bin/dropbearkey";

  sshdScript = pkgs.writeShellScript "termux-sshd" ''
    # termux-sshd — POSIX wrapper for Termux SSHD (dropbear)
    # Usage: termux-sshd [start|stop|status|restart]
    # Listens on port 8022 (no root needed).

    DROPBEAR_BIN="${dropbearBin}"
    DROPBEARKEY_BIN="${dropbearKeyBin}"

    PID_FILE="$HOME/.cache/sshd.pid"
    LOG_FILE="$HOME/.cache/sshd.log"
    ED25519_KEY="$HOME/.ssh/dropbear_ed25519_host_key"
    RSA_KEY="$HOME/.ssh/dropbear_rsa_host_key"

    is_running() {
      [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
    }

    do_start() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "sshd already running (PID $pid) on :8022"
        return 0
      fi

      mkdir -p ~/.ssh "$(dirname "$PID_FILE")"
      chmod 700 ~/.ssh

      # Generate dropbear host keys if missing (dropbear uses its own format,
      # NOT OpenSSH's; can't reuse ssh_host_ed25519_key from openssh).
      [ -f "$ED25519_KEY" ] || "$DROPBEARKEY_BIN" -t ed25519 -f "$ED25519_KEY" >/dev/null 2>&1
      [ -f "$RSA_KEY" ]     || "$DROPBEARKEY_BIN" -t rsa     -f "$RSA_KEY"     -s 2048 >/dev/null 2>&1

      # Authorized keys live at ~/.ssh/authorized_keys (deployed by home.file).
      # dropbear reads it automatically.
      if [ -x "$DROPBEAR_BIN" ]; then
        # -p PORT, -r KEY (repeat for each algo), -P PIDFILE, -E log to stderr
        # No -F: dropbear backgrounds itself by default and writes the pidfile.
        "$DROPBEAR_BIN" -p 8022 -r "$ED25519_KEY" -r "$RSA_KEY" -P "$PID_FILE" -E >> "$LOG_FILE" 2>&1
        sleep 0.3
        if is_running; then
          pid=$(cat "$PID_FILE")
          echo "sshd started (PID $pid) on :8022"
        else
          echo "sshd failed to start — check $LOG_FILE"
          tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
          return 1
        fi
      else
        echo "ERROR: dropbear binary not found at $DROPBEAR_BIN"
        return 1
      fi
    }

    do_stop() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo "sshd stopped (was PID $pid)"
      else
        rm -f "$PID_FILE"
        echo "sshd not running"
      fi
    }

    do_status() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "sshd running (PID $pid) on :8022"
      else
        rm -f "$PID_FILE"
        echo "sshd not running"
      fi
    }

    case "''${1:-start}" in
      start)   do_start ;;
      stop)    do_stop ;;
      status)  do_status ;;
      restart) do_stop; sleep 0.3; do_start ;;
      *)       echo "Usage: termux-sshd {start|stop|status|restart}"; exit 1 ;;
    esac
  '';
in
{
  # Make dropbear available as a system package so it's in the closure even
  # though we invoke it by absolute path in the wrapper.
  home.packages = [ pkgs.dropbear ];

  # Deploy the wrapper
  home.file.".local/bin/termux-sshd" = {
    source = sshdScript;
    executable = true;
  };

  # Deploy authorized_keys declaratively (data-driven from data/authorized-keys.json)
  home.file.".ssh/authorized_keys" = {
    text = authorizedKeysContent;
  };

  # Auto-start sshd on shell init (fish)
  programs.fish.shellInit = lib.mkAfter ''
    if not test -f $HOME/.cache/sshd.pid; or not kill -0 (cat $HOME/.cache/sshd.pid 2>/dev/null) 2>/dev/null
      termux-sshd start >/dev/null 2>&1
    end
  '';
}
