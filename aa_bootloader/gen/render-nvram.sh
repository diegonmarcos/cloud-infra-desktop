#!/bin/sh
# render-nvram.sh — Phase 3 STUB
# Will emit dist/nvram/apply.sh: idempotent efibootmgr commands to ensure
# NVRAM matches boot.json's uefi.nvram.entries and removes uefi.nvram.remove_stale.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"

DIST="$ROOT_DIR/dist/nvram"
mkdir -p "$DIST"

cat > "$DIST/apply.sh" <<'EOF'
#!/bin/sh
# Phase 3 stub. NVRAM is currently managed by NixOS (canTouchEfiVariables=true).
# When Phase 3 lands, this script will replace NixOS's NVRAM management.
echo "[nvram/apply.sh] Phase 3 stub — no NVRAM changes performed."
exit 0
EOF
chmod +x "$DIST/apply.sh"

warn "render-nvram.sh is a Phase 3 stub — no real NVRAM logic yet"
