# Shared logging helpers (POSIX, sourced by all src/gen/*.sh)
# Borrowed from the previous build.sh.

# Colors (POSIX-safe)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()    { printf "${GREEN}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1"; }
warn()   { printf "${YELLOW}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }
error()  { printf "${RED}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }
header() {
    printf "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
    printf "${BOLD}%s${NC}\n" "$1"
    printf "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
}
