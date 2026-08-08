# trim-generations — keep the 2 newest generations every switch; full GC only
# under disk pressure. nix-collect-garbage per switch evicted the kernel page
# cache (11s directory lookups, 4-minute claude cold start measured after a
# 5156-path GC). Env contract: NIX_DIR (…/bin), AWK_BIN.
"$NIX_DIR/nix-env" -p /nix/var/nix/profiles/nix-on-droid --delete-generations +2 2>/dev/null || true
"$NIX_DIR/nix-env" -p "$HOME/.local/state/nix/profiles/home-manager" --delete-generations +2 2>/dev/null || true
"$NIX_DIR/nix-env" -p /nix/var/nix/profiles/per-user/nix-on-droid/profile --delete-generations +2 2>/dev/null || true
_free_kb=$(df -k "$HOME" 2>/dev/null | "$AWK_BIN" 'NR==2 {print $4}')
if [ "${FORCE_GC:-0}" = 1 ] || [ "${_free_kb:-0}" -lt 4194304 ]; then
  echo "[trim-generations] GC running (free=$((_free_kb / 1048576))GiB < 4GiB or FORCE_GC=1) — this deletes store paths AND evicts warm page cache; expect minutes"
  _gc_t0=$(date +%s)
  "$NIX_DIR/nix-collect-garbage" 2>/dev/null || true
  echo "[trim-generations] GC done in $(( $(date +%s) - _gc_t0 ))s"
else
  echo "[trim-generations] GC skipped (free=$((_free_kb / 1048576))GiB ≥ 4GiB — FORCE_GC=1 to force)"
fi
