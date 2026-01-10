#!/bin/sh
# Build claude-sandbox distributions
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/src/nix"
DIST="$BASE/dist"
LIBS="$BASE/libs"

mkdir -p "$DIST" "$LIBS"

# Download nix-portable
if [ ! -f "$LIBS/nix-portable" ]; then
    echo "Downloading nix-portable..."
    curl -L -o "$LIBS/nix-portable" \
        "https://github.com/DavHau/nix-portable/releases/download/v012/nix-portable-x86_64"
    chmod +x "$LIBS/nix-portable"
fi

# Build tar.gz
echo "Building tar.gz..."
rm -rf "$LIBS/tar"
mkdir -p "$LIBS/tar/claude"
cp "$SRC/flake.nix" "$LIBS/tar/claude/"
cp "$LIBS/nix-portable" "$LIBS/tar/claude/"

cat > "$LIBS/tar/claude/run.sh" << 'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
export NP_RUNTIME=bwrap
exec "$DIR/nix-portable" nix --option sandbox false run "$DIR#default" -- "$@"
EOF
chmod +x "$LIBS/tar/claude/run.sh"

cd "$LIBS/tar"
tar -czf "$DIST/claude.tar.gz" claude/
echo "  -> $DIST/claude.tar.gz"

# Build AppImage
echo "Building AppImage..."
rm -rf "$LIBS/appimage"
APPDIR="$LIBS/appimage/Claude_Sandbox.AppDir"
mkdir -p "$APPDIR"

cp "$SRC/flake.nix" "$APPDIR/"
cp "$LIBS/nix-portable" "$APPDIR/"

cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/sh
# Always use extraction - FUSE doesn't work reliably
if [ -z "$APPIMAGE_EXTRACT_AND_RUN" ]; then
    export APPIMAGE_EXTRACT_AND_RUN=1
    exec "$APPIMAGE" "$@"
fi

DIR="$(dirname "$(readlink -f "$0")")"
export NP_RUNTIME=bwrap
exec "$DIR/nix-portable" nix --option sandbox false run "$DIR#default" -- "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/claude.desktop" << 'EOF'
[Desktop Entry]
Name=Claude
Exec=AppRun
Icon=claude
Type=Application
Categories=Development;
Terminal=true
EOF

cat > "$APPDIR/claude.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<rect width="100" height="100" rx="20" fill="#1a1a2e"/>
<text x="50" y="65" font-size="50" text-anchor="middle" fill="#d4a574">C</text>
</svg>
EOF

APPIMAGETOOL="$BASE/src/AppImage/appimagetool-x86_64.AppImage"
cd "$LIBS/appimage"
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$DIST/claude.AppImage" 2>/dev/null
echo "  -> $DIST/claude.AppImage"

echo ""
echo "Done!"
ls -lh "$DIST"
