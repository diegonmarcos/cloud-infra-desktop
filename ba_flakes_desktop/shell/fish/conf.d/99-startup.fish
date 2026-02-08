# =============================================================================
# FISH STARTUP - Welcome screen with system info
# Source: shell/fish/conf.d/99-startup.fish
# =============================================================================

# =============================================================================
# SYSTEM INFO FUNCTIONS
# =============================================================================

function _get_system_info
    set -l os_name (uname -s)
    set -l kernel_version (uname -r)
    set -l hostname_str (hostname)
    set -l uptime_str (uptime -p 2>/dev/null; or uptime | awk '{print $3, $4}' | sed 's/,//')
    set -l cpu_model (lscpu 2>/dev/null | grep "Model name:" | sed 's/Model name:\s*//' | head -1)
    set -l mem_total (free -h 2>/dev/null | awk '/Mem:/ {print $2}')
    set -l mem_used (free -h 2>/dev/null | awk '/Mem:/ {print $3}')

    printf "\x1b[1;36mSYSTEM\x1b[0m\n"
    printf "  OS:       \x1b[1;37m%s\x1b[0m\n" "$os_name"
    printf "  Kernel:   \x1b[1;37m%s\x1b[0m\n" "$kernel_version"
    printf "  Host:     \x1b[1;37m%s\x1b[0m\n" "$hostname_str"
    printf "  Uptime:   \x1b[1;37m%s\x1b[0m\n" "$uptime_str"
    printf "  CPU:      \x1b[1;37m%s\x1b[0m\n" "$cpu_model"
    printf "  Memory:   \x1b[1;37m%s / %s\x1b[0m\n" "$mem_used" "$mem_total"
end

function _get_network_info
    set -l ip_address (ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    set -l gateway (ip route 2>/dev/null | grep default | awk '{print $3; exit}')

    printf "\x1b[1;36mNETWORK\x1b[0m\n"
    printf "  IP:       \x1b[1;37m%s\x1b[0m\n" "$ip_address"
    printf "  Gateway:  \x1b[1;37m%s\x1b[0m\n" "$gateway"
end

function _get_disk_usage
    set -l disk_info (df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')

    printf "\x1b[1;36mDISK\x1b[0m\n"
    printf "  Root:     \x1b[1;37m%s\x1b[0m\n" "$disk_info"
end

function _get_mounts
    printf "\x1b[1;36mMOUNTS\x1b[0m\n"
    if mount | grep -q rclone 2>/dev/null
        for line in (mount | grep rclone)
            printf "  \x1b[1;32m●\x1b[0m %s\n" (echo $line | awk '{print $3}')
        end
    else
        printf "  \x1b[1;30mNo rclone mounts\x1b[0m\n"
    end
end

function _show_quick_ref
    printf "\x1b[1;36mQUICK REFERENCE\x1b[0m\n"
    printf "  \x1b[1;33mNavigation:\x1b[0m  ..  ...  ....  mkcd <dir>\n"
    printf "  \x1b[1;33mListing:\x1b[0m     ll  la  lh  lt\n"
    printf "  \x1b[1;33mGit:\x1b[0m         gs  ga  gc  gp  gl  gd  gcam  gpsh  push\n"
    printf "  \x1b[1;33mDocker:\x1b[0m      dps  dpsa  dcu  dcd  dlog  dex\n"
    printf "  \x1b[1;33mSystem:\x1b[0m      df  free  ports  myip  cpucap\n"
    printf "  \x1b[1;33mTools:\x1b[0m       extract  backup  qfind  pyp\n"
    printf "  \x1b[1;33mHelp:\x1b[0m        myhelp  show_aliases  show_functions\n"
end

function _show_ascii_art
    printf "\x1b[1;34m"
    echo '
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
'
    printf "\x1b[0m"
end

# =============================================================================
# MAIN WELCOME SCREEN
# =============================================================================

function _show_welcome
    clear

    # Header
    printf "\x1b[1;34mWelcome to Fish, %s!\x1b[0m\n" (whoami)
    printf "\x1b[1;30m%s\x1b[0m\n\n" (date "+%A, %B %d, %Y - %I:%M %p")

    # System info
    _get_system_info
    echo
    _get_network_info
    echo
    _get_disk_usage
    echo
    _get_mounts
    echo
    _show_quick_ref

    # ASCII art
    _show_ascii_art

    # Footer
    printf "\x1b[1;32mHave a productive day!\x1b[0m\n\n"
end

# =============================================================================
# AUTO-START SERVICES
# =============================================================================

function _startup_services
    # Rclone mount check (silent)
    if not mount | grep -q "/home/diego/Documents/Gdrive" 2>/dev/null
        if test -x "/home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh"
            bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh a2 &>/dev/null &
            disown 2>/dev/null
        end
    end
end

# =============================================================================
# RUN STARTUP
# =============================================================================

# Only run in interactive shells
if status is-interactive
    _startup_services
    _show_welcome
end
