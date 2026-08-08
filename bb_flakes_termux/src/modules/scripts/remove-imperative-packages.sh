# remove-imperative-packages — HM always wins: drop imperative nix profile
# installs that would conflict. Env contract: NIX_DIR (…/bin) — activation
# PATH has no nix (`command -v nix` made this a permanent silent no-op).
if "$NIX_DIR/nix" profile list >/dev/null 2>&1; then
  "$NIX_DIR/nix" profile list 2>/dev/null | grep "^Name:" | sed 's/.*Name:[[:space:]]*//' | sed 's/\x1b\[[0-9;]*m//g' | while read -r pkg; do
    echo "[hm] Removing imperative nix profile package: $pkg"
    "$NIX_DIR/nix" profile remove "$pkg" 2>/dev/null || true
  done
fi
