#!/usr/bin/env bash
# Force jemalloc for this process tree
export LD_PRELOAD="@jemalloc@/lib/libjemalloc.so"

# Aggressive Node/V8 settings to prevent crashes
export NODE_OPTIONS="--max-old-space-size=256 --v8-pool-size=1"
export UV_THREADPOOL_SIZE=1
export VSCODE_DISABLE_FILE_WATCHER=1

# Disable features that cause issues on Android
export ELECTRON_DISABLE_SANDBOX=1
export ELECTRON_NO_ATTACH_CONSOLE=1

# Colors
C_RESET="\033[0m"
C_CYAN="\033[0;36m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_MAGENTA="\033[0;35m"
C_BLUE="\033[0;34m"

LOG_FILE="$HOME/.cache/code-server.log"
PID_FILE="$HOME/.cache/code-server.pid"

get_lan_ip() {
  @python3_bin@/python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "<no-network>"
}

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

case "${1:-}" in
  local)
    if is_running; then
      printf "${C_YELLOW}code-server already running (PID: $(cat "$PID_FILE"))${C_RESET}\n"
      exit 0
    fi
    printf "${C_CYAN}Starting code-server on localhost:8080...${C_RESET}\n"
    mkdir -p "$(dirname "$LOG_FILE")"
    nohup @code_server_bin@/code-server --bind-addr 127.0.0.1:8080 --auth none --disable-workspace-trust --disable-telemetry > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if is_running; then
      printf "${C_GREEN}Started on http://127.0.0.1:8080${C_RESET}\n"
    else
      printf "${C_RED}Failed to start. Check $LOG_FILE${C_RESET}\n"
    fi
    ;;
  lan)
    if is_running; then
      printf "${C_YELLOW}code-server already running (PID: $(cat "$PID_FILE"))${C_RESET}\n"
      exit 0
    fi
    LAN_IP=$(get_lan_ip)
    printf "${C_CYAN}Starting code-server on LAN (daemon)...${C_RESET}\n"
    mkdir -p "$(dirname "$LOG_FILE")"
    nohup @code_server_bin@/code-server --bind-addr 0.0.0.0:8080 --disable-workspace-trust --disable-telemetry > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if is_running; then
      printf "${C_GREEN}Started on http://$LAN_IP:8080${C_RESET}\n"
      printf "${C_MAGENTA}Password:${C_RESET} $(grep "^password:" ~/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo 'not set')\n"
    else
      printf "${C_RED}Failed to start. Check $LOG_FILE${C_RESET}\n"
    fi
    ;;
  stop)
    printf "${C_YELLOW}Stopping code-server...${C_RESET}\n"
    if is_running; then
      kill "$(cat "$PID_FILE")" 2>/dev/null
      rm -f "$PID_FILE"
    fi
    ps aux 2>/dev/null | grep "code-server" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
    sleep 1
    printf "${C_GREEN}Stopped.${C_RESET}\n"
    ;;
  log)
    if [ -f "$LOG_FILE" ]; then
      tail -50 "$LOG_FILE"
    else
      printf "${C_RED}No log file found${C_RESET}\n"
    fi
    ;;
  *)
    LAN_IP=$(get_lan_ip)
    printf "${C_CYAN}=== code-server ===${C_RESET}\n"
    if is_running; then
      printf "${C_GREEN}RUNNING${C_RESET} (PID: $(cat "$PID_FILE"))\n"
      printf "  Local: ${C_CYAN}http://127.0.0.1:8080${C_RESET}\n"
      printf "  LAN:   ${C_CYAN}http://$LAN_IP:8080${C_RESET}\n"
    else
      printf "${C_RED}STOPPED${C_RESET}\n"
    fi
    echo ""
    printf "${C_YELLOW}Commands:${C_RESET}\n"
    printf "  ${C_BLUE}code local${C_RESET}   Start on localhost (daemon)\n"
    printf "  ${C_BLUE}code lan${C_RESET}     Start on LAN (daemon)\n"
    printf "  ${C_BLUE}code stop${C_RESET}    Stop code-server\n"
    printf "  ${C_BLUE}code log${C_RESET}     Show recent logs\n"
    echo ""
    printf "${C_MAGENTA}Password:${C_RESET} $(grep "^password:" ~/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo 'not set')\n"
    echo ""
    printf "${C_RED}Note:${C_RESET} Terminal/extensions may crash on Android.\n"
    printf "       Access from another device for best experience.\n"
    ;;
esac
