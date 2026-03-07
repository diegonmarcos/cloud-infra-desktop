#!/bin/bash
# Setup script for flatpak-box distrobox
#
# This script builds the container image and creates the distrobox
#
# Usage: ./setup.sh [build|create|export|all|remove]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="flatpak-box"
BOX_NAME="flatpak-box"

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build   - Build the container image"
    echo "  create  - Create the distrobox (requires image)"
    echo "  export  - Export all apps to host desktop"
    echo "  all     - Build, create, and export (full setup)"
    echo "  remove  - Remove distrobox and image"
    echo "  status  - Show current status"
    echo ""
}

build_image() {
    echo "=== Building container image ==="
    cd "$SCRIPT_DIR"

    # Use podman if available, otherwise docker
    if command -v podman &> /dev/null; then
        podman build -t "$IMAGE_NAME" -f Containerfile .
    else
        docker build -t "$IMAGE_NAME" -f Containerfile .
    fi

    echo "Image '$IMAGE_NAME' built successfully"
}

create_box() {
    echo "=== Creating distrobox ==="

    # Check if already exists
    if distrobox list | grep -q "$BOX_NAME"; then
        echo "Distrobox '$BOX_NAME' already exists"
        return 0
    fi

    distrobox create --image "localhost/$IMAGE_NAME" --name "$BOX_NAME"
    echo "Distrobox '$BOX_NAME' created successfully"
}

export_apps() {
    echo "=== Exporting apps to host ==="
    "$SCRIPT_DIR/export-apps.sh"
}

remove_box() {
    echo "=== Removing distrobox and image ==="

    # Stop and remove distrobox
    if distrobox list | grep -q "$BOX_NAME"; then
        distrobox stop "$BOX_NAME" || true
        distrobox rm "$BOX_NAME"
        echo "Distrobox '$BOX_NAME' removed"
    fi

    # Remove image
    if command -v podman &> /dev/null; then
        podman rmi "$IMAGE_NAME" 2>/dev/null || true
    else
        docker rmi "$IMAGE_NAME" 2>/dev/null || true
    fi
    echo "Image '$IMAGE_NAME' removed"

    # Clean up desktop files
    rm -f ~/.local/share/applications/flatpak-box-*.desktop
    echo "Desktop entries cleaned"
}

show_status() {
    echo "=== Distrobox Status ==="
    distrobox list
    echo ""
    echo "=== Flatpak Apps in Box ==="
    distrobox enter "$BOX_NAME" -- flatpak list --app --columns=application,name 2>/dev/null || echo "Box not running"
}

case "${1:-}" in
    build)
        build_image
        ;;
    create)
        create_box
        ;;
    export)
        export_apps
        ;;
    all)
        build_image
        create_box
        # Start the box first
        distrobox enter "$BOX_NAME" -- echo "Box started"
        export_apps
        echo ""
        echo "=== Setup Complete ==="
        echo "Your apps are now available in the application menu"
        ;;
    remove)
        remove_box
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
