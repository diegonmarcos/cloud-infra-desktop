# Termux SSHD — declarative SSH daemon on port 8022
# Provides: termux-sshd command (start|stop|status|restart)
# Auto-starts via shell init (add to fish/bash profile)
# Trusted pubkeys sourced from data/authorized-keys.json (data-driven)
{ config, pkgs, lib, ... }:

let
  authData = builtins.fromJSON (builtins.readFile ./data/authorized-keys.json);
  authorizedKeysContent =
    lib.concatStringsSep "\n" authData.trusted_pubkeys + "\n";

  # OpenSSH refuses to start unless invoked by an absolute path — it re-execs
  # itself for privilege separation and falls back to the original argv[0]. On
  # Termux the symlinked /bin/sshd path breaks that. Pin the absolute nix store
  # path of the sshd binary at flake-eval time.
  sshdBin = "${pkgs.openssh}/bin/sshd";
  sshKeygenBin = "${pkgs.openssh}/bin/ssh-keygen";

  sshdScript = pkgs.writeShellScript "termux-sshd" ''
    #!/bin/sh
    # termux-sshd — POSIX wrapper for Termux SSHD
    # Usage: termux-sshd [start|stop|status|restart]
    # Listens on port 8022 (Termux default, no root needed)
    #
    # NOTE: SSHD_BIN / SSH_KEYGEN_BIN are absolute nix store paths injected by
    # the flake. Required because OpenSSH re-exec needs an absolute path.

    SSHD_BIN="${sshdBin}"
    SSH_KEYGEN_BIN="${sshKeygenBin}"

    PID_FILE="$HOME/.cache/sshd.pid"
    LOG_FILE="$HOME/.cache/sshd.log"

    is_running() {
      [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
    }

    do_start() {
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "sshd already running (PID $pid) on :8022"
        return 0
      fi

      # Ensure host keys exist
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
      if [ ! -f ~/.ssh/ssh_host_ed25519_key ]; then
        "$SSH_KEYGEN_BIN" -t ed25519 -f ~/.ssh/ssh_host_ed25519_key -N "" -q
        echo "Generated host key: ~/.ssh/ssh_host_ed25519_key"
      fi

      # authorized_keys deployed declaratively by home.file (data/authorized-keys.json)
      mkdir -p "$(dirname "$PID_FILE")"

      # Start sshd via absolute nix store path (avoid PATH-resolved /bin/sshd
      # which breaks privsep re-exec on Termux/nix-on-droid).
      if [ -x "$SSHD_BIN" ]; then
        "$SSHD_BIN" -p 8022 -o "PidFile=$PID_FILE" -o "HostKey=$HOME/.ssh/ssh_host_ed25519_key" >> "$LOG_FILE" 2>&1
        sleep 0.5
        if is_running; then
          pid=$(cat "$PID_FILE")
          echo "sshd started (PID $pid) on :8022"
        else
          echo "sshd failed to start — check $LOG_FILE"
          tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
          return 1
        fi
      else
        echo "ERROR: sshd binary not found at $SSHD_BIN"
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
      restart) do_stop; sleep 0.5; do_start ;;
      *)       echo "Usage: termux-sshd {start|stop|status|restart}"; exit 1 ;;
    esac
  '';
in
{
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
  # This ensures sshd is always running when Termux is open
  programs.fish.shellInit = lib.mkAfter ''
    # Auto-start SSHD if not running
    if not test -f $HOME/.cache/sshd.pid; or not kill -0 (cat $HOME/.cache/sshd.pid 2>/dev/null) 2>/dev/null
      termux-sshd start >/dev/null 2>&1
    end
  '';
}
