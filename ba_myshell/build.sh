#!/bin/sh
# MyShell Build Script - Creates self-contained portable shell distributions
# Three profiles: shell (~200MB), minimum (~500MB), basic (~2-3GB)
# All builds are SELF-CONTAINED with bundled packages

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "${BLUE}ℹ${NC} %s\n" "$1"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
error() { printf "${RED}✗${NC} %s\n" "$1" >&2; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$1"; }

show_help() {
    cat << EOF
╔════════════════════════════════════════╗
║  MyShell Builder                       ║
║  Self-Contained Portable Shells        ║
╚════════════════════════════════════════╝

Usage:
  ./build.sh <PROFILE>

Profiles:
  shell      Shell essentials (~200MB self-contained)
             • zsh, fish shells
             • starship prompt
             • eza, bat, fzf, zoxide

  minimum    Shell + dev tools (~500MB self-contained)
             • All from Shell profile
             • + git, vim, ripgrep, fd
             • + curl, wget, jq, yazi

  basic      Full dev environment (~2-3GB self-contained)
             • All from Minimum profile
             • + Node.js, Python 3.11
             • + gcloud, rclone, wireguard
             • + Claude Code (npm install)

  all        Build all three profiles

Examples:
  ./build.sh shell       # Build shell profile
  ./build.sh minimum     # Build minimum profile
  ./build.sh basic       # Build basic profile
  ./build.sh all         # Build all profiles

All builds include:
  • nix-portable binary
  • Full Nix store (works offline)
  • Ready to tar and move anywhere

Dist folder structure:
  dist/shell/     : ~200MB (self-contained)
  dist/minimum/   : ~500MB (self-contained)
  dist/basic/     : ~2-3GB (self-contained)

EOF
}

build_profile() {
    PROFILE="$1"

    # Directories
    MYSHELL_DIR="$(cd "$(dirname "$0")" && pwd)"
    DIST_BASE="$MYSHELL_DIR/dist"
    DIST_DIR="$DIST_BASE/$PROFILE"

    # Select shell.nix file based on profile
    SHELL_NIX="$MYSHELL_DIR/src/${PROFILE}-profile.nix"

    if [ ! -f "$SHELL_NIX" ]; then
        error "Profile config not found: $SHELL_NIX"
        return 1
    fi

    # Profile size info
    case "$PROFILE" in
        shell)
            PROFILE_SIZE="~200MB"
            ;;
        minimum)
            PROFILE_SIZE="~500MB"
            ;;
        basic)
            PROFILE_SIZE="~2-3GB"
            ;;
    esac

    echo "╔════════════════════════════════════════╗"
    echo "║  MyShell Builder                       ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    info "Profile: $PROFILE (self-contained $PROFILE_SIZE)"
    echo ""

    # Clean dist folder
    info "Cleaning dist/$PROFILE/ folder..."
    chmod -R u+w "$DIST_DIR" 2>/dev/null || true
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR/_bundled"

    # Copy nix-portable binary
    cp "$MYSHELL_DIR/bin/nix-portable" "$DIST_DIR/_bundled/"

    # Copy profile config
    mkdir -p "$DIST_DIR/_bundled/config"
    cp "$SHELL_NIX" "$DIST_DIR/_bundled/config/shell.nix"

    # Copy README.md for tools reference
    cp "$MYSHELL_DIR/README.md" "$DIST_DIR/README.md"

    # Bundle mode - include nix store
    export NIX_PORTABLE_ROOT="$HOME/.nix-portable"

    # Ensure packages are downloaded
    info "Ensuring packages are downloaded..."
    "$MYSHELL_DIR/bin/nix-portable" nix-shell "$SHELL_NIX" --run 'echo "✓ Packages ready"' 2>&1 | grep -v "^╔" | grep -v "^║" | grep -v "^╚" | grep -v "^🏠" | grep -v "^🔗" | grep -v "Available" | grep -v "Tools included" | grep -v "Installing" | grep -v "To switch" | grep -v "To run" | grep -v "Profile ready" | grep -v "Claude Code" || true

    # Copy the entire nix-portable store (keep .nix-portable name!)
    info "Copying Nix store (this will take several minutes)..."
    if [ -d "$HOME/.nix-portable" ]; then
        # Use tar to preserve permissions and handle special files
        # IMPORTANT: Keep the .nix-portable directory name for nix-portable to find it
        (cd "$HOME" && tar cf - .nix-portable) | (cd "$DIST_DIR/_bundled" && tar xf -)
        success "Store copied"
    else
        error "No nix-portable store found at $HOME/.nix-portable"
        return 1
    fi

    SIZE=$(du -sh "$DIST_DIR" 2>/dev/null | cut -f1)

    # Create launcher script
    info "Creating launcher script..."
    cat > "$DIST_DIR/myshell" << 'LAUNCHER_EOF'
#!/bin/sh
# MyShell - Self-Contained Portable Nix Shell Environment
# Uses bwrap for real isolation in isolated mode

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

error() { printf "${RED}✗${NC} %s\n" "$1" >&2; }

# Find dist directory
DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLED_DIR="$DIST_DIR/_bundled"

# Export for shellHook
export MYSHELL_DIR="$DIST_DIR"
export NIX_PORTABLE_ROOT="$BUNDLED_DIR"

NIX_PORTABLE="$BUNDLED_DIR/nix-portable"
SHELL_NIX="$BUNDLED_DIR/config/shell.nix"

# Verify files exist
if [ ! -f "$NIX_PORTABLE" ]; then
    error "nix-portable not found at $NIX_PORTABLE"
    exit 1
fi

if [ ! -f "$SHELL_NIX" ]; then
    error "shell.nix not found at $SHELL_NIX"
    exit 1
fi

# Parse arguments
SHELL_TYPE="fish"
COMMAND=""
ISOLATION_MODE="true"

while [ $# -gt 0 ]; do
    case $1 in
        --fish|-f) SHELL_TYPE="fish"; shift ;;
        --zsh|-z) SHELL_TYPE="zsh"; shift ;;
        --bash|-b) SHELL_TYPE="bash"; shift ;;
        --isolated|-i) ISOLATION_MODE="true"; shift ;;
        --mirror|-m) ISOLATION_MODE="false"; shift ;;
        --command|-c) COMMAND="$2"; shift 2 ;;
        --help|-h)
            cat << EOF
MyShell - Self-Contained Portable Nix Shell Environment

Usage:
  $0 [OPTIONS] [COMMAND]

Options:
  -f, --fish      Start fish shell (default)
  -z, --zsh       Start zsh shell
  -b, --bash      Start bash shell
  -i, --isolated  Use isolated home with bwrap (default)
  -m, --mirror    Mirror real home (no sandbox)
  -c, --command   Run a command
  -h, --help      Show this help

EOF
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

export ISOLATION_MODE
REAL_HOME="$HOME"

if [ "$ISOLATION_MODE" = "true" ]; then
    # ISOLATED MODE: Use bwrap for real sandbox (with fallback)
    ISOLATED_HOME="$REAL_HOME/.temp/home-tmp"
    mkdir -p "$ISOLATED_HOME"
    mkdir -p "$ISOLATED_HOME/real-home" 2>/dev/null || true

    # Export for fallback mode
    export ISOLATED_HOME
    export REAL_HOME

    # Copy README.md into isolated home
    cp "$DIST_DIR/README.md" "$ISOLATED_HOME/README.md" 2>/dev/null || true

    # Welcome message function
    WELCOME="
echo '╔════════════════════════════════════════╗'
echo '║  MyShell - ISOLATED Mode               ║'
echo '╚════════════════════════════════════════╝'
echo ''
echo \"🏠 Isolated HOME: \$HOME\"
echo \"🔗 Real home: ~/real-home\"
echo ''
echo 'Shells: fish (default), zsh, bash'
echo ''
echo '📖 Full reference: bat ~/README.md'
echo ''
"

    if [ -n "$COMMAND" ]; then
        exec "$NIX_PORTABLE" nix-shell "$SHELL_NIX" --run "
            export HOME=$ISOLATED_HOME
            export REAL_HOME=$REAL_HOME
            ln -sfn $REAL_HOME $ISOLATED_HOME/real-home 2>/dev/null || true
            $COMMAND
        "
    else
        exec "$NIX_PORTABLE" nix-shell "$SHELL_NIX" --run "
            export HOME=$ISOLATED_HOME
            export REAL_HOME=$REAL_HOME
            ln -sfn $REAL_HOME $ISOLATED_HOME/real-home 2>/dev/null || true
            $WELCOME
            exec $SHELL_TYPE
        "
    fi
else
    # MIRROR MODE: Direct access, no sandbox
    WELCOME_MIRROR="
echo '╔════════════════════════════════════════╗'
echo '║  MyShell - MIRROR Mode                 ║'
echo '╚════════════════════════════════════════╝'
echo ''
echo \"🏠 Using real HOME: \$HOME\"
echo ''
echo 'Shells: fish (default), zsh, bash'
echo ''
echo '📖 Full reference: bat $DIST_DIR/README.md'
echo ''
"
    if [ -n "$COMMAND" ]; then
        exec "$NIX_PORTABLE" nix-shell "$SHELL_NIX" --run "$COMMAND"
    else
        exec "$NIX_PORTABLE" nix-shell "$SHELL_NIX" --run "
            $WELCOME_MIRROR
            exec $SHELL_TYPE
        "
    fi
fi
LAUNCHER_EOF

    chmod +x "$DIST_DIR/myshell"

    # Create convenience launchers
    cat > "$DIST_DIR/zsh-shell" << 'ZSH_EOF'
#!/bin/sh
exec "$(dirname "$0")/myshell" --zsh "$@"
ZSH_EOF

    cat > "$DIST_DIR/fish-shell" << 'FISH_EOF'
#!/bin/sh
exec "$(dirname "$0")/myshell" --fish "$@"
FISH_EOF

    chmod +x "$DIST_DIR/zsh-shell" "$DIST_DIR/fish-shell"

    # Summary
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║  Build Complete!                       ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    success "Profile: $PROFILE"
    success "Size: $SIZE (self-contained)"
    echo ""
    echo "To create portable archive:"
    echo "  tar czf myshell-$PROFILE.tar.gz dist/$PROFILE/"
    echo ""
    echo "To use:"
    echo "  ./dist/$PROFILE/myshell"
    echo "  ./dist/$PROFILE/myshell --zsh"
    echo "  ./dist/$PROFILE/myshell --fish"
    echo ""
}

# Main script
MYSHELL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check for nix-portable
if [ ! -f "$MYSHELL_DIR/bin/nix-portable" ]; then
    error "nix-portable not found at bin/nix-portable"
    echo "  Please download it first"
    exit 1
fi

# Parse arguments
PROFILE="${1:-}"

case "$PROFILE" in
    help|-h|--help|"")
        show_help
        exit 0
        ;;
    shell|minimum|basic)
        build_profile "$PROFILE"
        ;;
    all)
        build_profile "shell"
        echo ""
        build_profile "minimum"
        echo ""
        build_profile "basic"
        ;;
    *)
        error "Unknown profile: $PROFILE"
        echo "Run './build.sh help' for usage"
        exit 1
        ;;
esac
