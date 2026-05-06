#!/bin/sh
# render-nixos-adapter.sh — copy src/adapters/nixos/* + boot.json into dist/adapters/nixos/
# POSIX. Idempotent.
#
# Why a copy and not a symlink:
#   The NixOS flake imports these as flake-tracked source files. With pure-eval
#   (default), nix refuses to follow symlinks pointing outside the flake's
#   source root. Copying keeps everything inside the flake when build.sh
#   deploy --target nixos runs.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"

SRC="$ROOT_DIR/src/adapters/nixos"
SRC_JSON="$ROOT_DIR/src/boot.json"
DIST="$ROOT_DIR/dist/adapters/nixos"

mkdir -p "$DIST"

log "Rendering NixOS adapter → $DIST"

# 1. Copy boot.json so .nix can read it via builtins.readFile ./boot.json
cp -f "$SRC_JSON" "$DIST/boot.json"

# 2. Copy each adapter .nix file
for f in "$SRC"/*.nix; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    cp -f "$f" "$DIST/$name"
done

# 3. Drop a small README in dist so users opening it know what's what
cat > "$DIST/README.md" <<'EOF'
# dist/adapters/nixos/

GENERATED. Do not edit.

The .nix files here are copied verbatim from `aa_bootloader/src/adapters/nixos/`
by `gen/render-nixos-adapter.sh`. `boot.json` is copied from `aa_bootloader/src/`.

`src/gen/deploy-nixos.sh` copies this directory's contents into the NixOS
flake at `aa_nixos-surface_host/src/modules/`, then triggers nixos-rebuild.

To change the contents: edit `aa_bootloader/src/`, run
`aa_bootloader/build.sh generate`, then `build.sh deploy --target nixos`.
EOF

log "Wrote: $(cd "$DIST" && ls -1 | tr '\n' ' ')"
