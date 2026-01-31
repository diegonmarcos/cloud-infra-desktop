#!/bin/bash
# =============================================================================
# BASH STARTUP - Welcome screen with system info
# Source: shell/bash/startup.bash
# =============================================================================

# Colors
_RST="\033[0m"
_RED="\033[1;31m"
_GREEN="\033[1;32m"
_YELLOW="\033[1;33m"
_BLUE="\033[1;34m"
_MAGENTA="\033[1;35m"
_CYAN="\033[1;36m"
_GRAY="\033[1;30m"
_WHITE="\033[1;37m"
_BOLD="\033[1m"

# =============================================================================
# SYSTEM INFO FUNCTIONS
# =============================================================================

_get_system_info() {
    local os_name=$(uname -s)
    local kernel_version=$(uname -r)
    local hostname_str=$(hostname)
    local uptime_str=$(uptime -p 2>/dev/null || uptime | awk '{print $3, $4}' | sed 's/,//')
    local cpu_model=$(lscpu 2>/dev/null | grep "Model name:" | sed 's/Model name:\s*//' | head -1)
    local mem_total=$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')
    local mem_used=$(free -h 2>/dev/null | awk '/Mem:/ {print $3}')

    echo -e "${_CYAN}SYSTEM${_RST}"
    echo -e "  OS:       ${_WHITE}$os_name${_RST}"
    echo -e "  Kernel:   ${_WHITE}$kernel_version${_RST}"
    echo -e "  Host:     ${_WHITE}$hostname_str${_RST}"
    echo -e "  Uptime:   ${_WHITE}$uptime_str${_RST}"
    echo -e "  CPU:      ${_WHITE}${cpu_model:-N/A}${_RST}"
    echo -e "  Memory:   ${_WHITE}${mem_used:-?} / ${mem_total:-?}${_RST}"
}

_get_network_info() {
    local ip_address=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    local gateway=$(ip route 2>/dev/null | grep default | awk '{print $3; exit}')

    echo -e "${_CYAN}NETWORK${_RST}"
    echo -e "  IP:       ${_WHITE}${ip_address:-N/A}${_RST}"
    echo -e "  Gateway:  ${_WHITE}${gateway:-N/A}${_RST}"
}

_get_disk_usage() {
    local disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')

    echo -e "${_CYAN}DISK${_RST}"
    echo -e "  Root:     ${_WHITE}${disk_info:-N/A}${_RST}"
}

_get_mounts() {
    echo -e "${_CYAN}MOUNTS${_RST}"
    if mount | grep -q rclone 2>/dev/null; then
        mount | grep rclone | while read -r line; do
            echo -e "  ${_GREEN}●${_RST} $(echo "$line" | awk '{print $3}')"
        done
    else
        echo -e "  ${_GRAY}No rclone mounts${_RST}"
    fi
}

_show_quick_ref() {
    echo -e "${_CYAN}QUICK REFERENCE${_RST}"
    echo -e "  ${_YELLOW}Navigation:${_RST}  ..  ...  ....  mkcd <dir>"
    echo -e "  ${_YELLOW}Listing:${_RST}     ll  la  lh  lt"
    echo -e "  ${_YELLOW}Git:${_RST}         gs  ga  gc  gp  gl  gd  gcam  gpsh"
    echo -e "  ${_YELLOW}Docker:${_RST}      dps  dpsa  dcu  dcd  dlog  dex"
    echo -e "  ${_YELLOW}System:${_RST}      df  free  ports  myip  cpucap"
    echo -e "  ${_YELLOW}Tools:${_RST}       extract  backup  qfind  pyp"
    echo -e "  ${_YELLOW}Help:${_RST}        myhelp  show_aliases  show_functions"
}

# =============================================================================
# ASCII ART
# =============================================================================

_show_ascii_art() {
    echo -e "${_BLUE}"
    cat << 'EOF'
           _               _
       _  /\ \           /\ \
      /\_\\ \ \         /  \ \
     / / / \ \ \       / /\ \ \
    / / /   \ \ \      \/_/\ \ \
    \ \ \____\ \ \         / / /
     \ \________\ \       / / /
      \/________/\ \     / / /  _
                \ \ \   / / /_/\_\
                 \ \_\ / /_____/ /
                  \/_/ \________/
EOF
    echo -e "${_RST}"
}

# =============================================================================
# MAIN WELCOME SCREEN
# =============================================================================

_show_welcome() {
    clear

    # Header
    echo -e "${_BOLD}${_BLUE}Welcome to Bash, $(whoami)!${_RST}"
    echo -e "${_GRAY}$(date "+%A, %B %d, %Y - %I:%M %p")${_RST}"
    echo ""

    # Two-column layout simulation
    _get_system_info
    echo ""
    _get_network_info
    echo ""
    _get_disk_usage
    echo ""
    _get_mounts
    echo ""
    _show_quick_ref

    # ASCII art
    _show_ascii_art

    # Footer
    echo -e "${_GREEN}Have a productive day!${_RST}\n"
}

# =============================================================================
# AUTO-START SERVICES
# =============================================================================

_startup_services() {
    # Rclone mount check (silent)
    if ! mount | grep -q "/home/diego/Documents/Gdrive" 2>/dev/null; then
        if [ -x "/home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh" ]; then
            bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh a2 &>/dev/null &
        fi
    fi
}

# =============================================================================
# RUN STARTUP
# =============================================================================

# Only run in interactive shells
if [[ $- == *i* ]]; then
    _startup_services
    _show_welcome
fi
