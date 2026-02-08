#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAKE_DIR="$SCRIPT_DIR"
TARGET_DIR="$HOME/.config/nix-on-droid"

# ==============================================================================
# USAGE
# ==============================================================================
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  switch    Build from flake and apply configuration"
    echo "  update    Update flake inputs (nixpkgs, nix-on-droid, home-manager)"
    echo "  setup     Full initial setup (storage, compatibility dirs, then switch)"
    echo "  help      Show this help message"
    echo ""
    echo "If no command is given, 'setup' is run."
}

# ==============================================================================
# ENSURE COMPATIBILITY DIRECTORIES
# ==============================================================================
ensure_compat_dirs() {
    if [ ! -d "/data/data/com.termux.nix/files/usr/lib" ]; then
        echo "  Creating compatibility directory: /usr/lib..."
        mkdir -p /data/data/com.termux.nix/files/usr/lib
        chmod 755 /data/data/com.termux.nix/files/usr/lib
    fi
}

# ==============================================================================
# STORAGE SETUP
# ==============================================================================
setup_storage() {
    echo " Setting up Android Storage Access..."

    if [ -d "/storage/emulated/0" ] && [ ! -L "$HOME/storage" ] && [ ! -d "$HOME/storage" ]; then
        echo "    Found /storage/emulated/0, creating symlink..."
        ln -sf /storage/emulated/0 "$HOME/storage" 2>/dev/null
        if [ -L "$HOME/storage" ]; then
            echo "    Storage linked successfully at ~/storage"
        else
            echo "    Could not create symlink. Check app permissions in Android Settings."
        fi
    elif [ -L "$HOME/storage" ] || [ -d "$HOME/storage" ]; then
        echo "    Storage already configured at ~/storage"
    elif command -v termux-setup-storage >/dev/null 2>&1; then
        echo "    Using termux-setup-storage fallback..."
        termux-setup-storage
        echo "    A POPUP should appear on your phone. Please tap 'ALLOW'."
        sleep 3
    else
        echo "    Warning: Cannot access /storage/emulated/0"
        echo "    Grant storage permission in Android Settings -> Apps -> Nix-on-Droid"
    fi
}

# ==============================================================================
# COPY FLAKE TO SYSTEM LOCATION
# ==============================================================================
copy_flake() {
    echo " Copying flake to $TARGET_DIR..."
    mkdir -p "$TARGET_DIR"

    # Copy flake files
    cp "$FLAKE_DIR/flake.nix" "$TARGET_DIR/"

    # Copy lock file if it exists
    if [ -f "$FLAKE_DIR/flake.lock" ]; then
        cp "$FLAKE_DIR/flake.lock" "$TARGET_DIR/"
    fi

    echo "    Flake copied successfully."
}

# ==============================================================================
# SWITCH (BUILD AND APPLY)
# ==============================================================================
do_switch() {
    echo " Building and switching configuration..."
    ensure_compat_dirs
    copy_flake

    # Build and switch using flake
    nix-on-droid switch --flake "$TARGET_DIR"

    # Copy back the lock file if it was updated
    if [ -f "$TARGET_DIR/flake.lock" ]; then
        cp "$TARGET_DIR/flake.lock" "$FLAKE_DIR/"
    fi

    echo " Switch complete! Restart Termux to apply all changes."
}

# ==============================================================================
# UPDATE FLAKE INPUTS
# ==============================================================================
do_update() {
    echo " Updating flake inputs..."

    # Update in the source directory
    nix flake update "$FLAKE_DIR"

    echo " Inputs updated. Run '$0 switch' to apply."
}

# ==============================================================================
# FULL SETUP (INITIAL INSTALL)
# ==============================================================================
do_setup() {
    echo "  Starting Full Nix-on-Droid Flake Setup..."

    ensure_compat_dirs
    setup_storage

    echo " Installing flake configuration..."
    copy_flake

    echo " Building your new environment..."
    nix-on-droid switch --flake "$TARGET_DIR"

    # Copy back the lock file
    if [ -f "$TARGET_DIR/flake.lock" ]; then
        cp "$TARGET_DIR/flake.lock" "$FLAKE_DIR/"
    fi

    echo " ALL DONE! Restart Termux to see your new Fish shell."
}

# ==============================================================================
# MAIN
# ==============================================================================
case "${1:-setup}" in
    switch)
        do_switch
        ;;
    update)
        do_update
        ;;
    setup)
        do_setup
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
