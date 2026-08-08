# link-nix-bins-termux — expose nix-profile binaries in the plain-Termux
# prefix so Android launchers/apps can find them. Repairs dangling links
# (a package leaving the profile used to strand its old link forever).
TERMUX_BIN="/data/data/com.termux.nix/files/usr/bin"
NIX_BIN="$HOME/.nix-profile/bin"
if [ -d "$TERMUX_BIN" ] && [ -d "$NIX_BIN" ]; then
  for f in "$NIX_BIN"/*; do
    name="$(basename "$f")"
    target="$TERMUX_BIN/$name"
    if { [ ! -e "$target" ] && [ ! -L "$target" ]; } || { [ -L "$target" ] && [ ! -e "$target" ]; }; then
      ln -sf "$f" "$target"
    fi
  done
fi
