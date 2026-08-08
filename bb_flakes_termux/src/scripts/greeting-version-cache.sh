# greeting-version-cache — CLI versions + store-path count computed ONCE per
# switch. fish_greeting used to spawn claude/goose/ant (up to 9s of
# timeout-blocking) and readdir all of /nix/store on EVERY new shell.
mkdir -p "$HOME/.cache"
_v() { timeout 30 "$1" --version 2>/dev/null | grep -oE '[0-9][0-9.]*' | head -1; }
{
  v=$(_v "$HOME/.nix-profile/bin/claude"); printf 'claude %s\n' "${v:-n/a}"
  v=$(_v "$HOME/.nix-profile/bin/goose");  printf 'goose %s\n'  "${v:-n/a}"
  v=$(_v "$HOME/.nix-profile/bin/ant");    printf 'ant %s\n'    "${v:-n/a}"
} > "$HOME/.cache/greeting-versions" || true
ls /nix/store 2>/dev/null | wc -l | tr -d ' ' > "$HOME/.cache/greeting-storecount" || true
echo "[greeting-cache] CLI versions + store count refreshed"
