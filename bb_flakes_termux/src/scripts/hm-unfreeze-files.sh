# hm-unfreeze-files — swap store-backed HM symlinks for writable copies so
# deployed dotfiles are editable for imperative tests; the next switch
# re-links then re-copies (declarative always wins). Env contract:
# TARGETS_FILE (list of home-relative paths, one per line).
while IFS= read -r _rel; do
  [ -n "$_rel" ] || continue
  # cloud-marketplace stays a store symlink: deep-copying the plugin tree
  # through proot every switch is expensive AND breaks the store-backed
  # marketplace contract claude-marketplace-register relies on.
  case "$_rel" in .claude/cloud-marketplace*) continue ;; esac
  _t="$HOME/$_rel"
  [ -L "$_t" ] || continue
  _r="$(readlink -f "$_t" 2>/dev/null)"
  [ -n "$_r" ] && [ -e "$_r" ] || continue
  case "$_r" in /nix/store/*) ;; *) continue ;; esac
  rm -f "$_t"
  cp -RL "$_r" "$_t"
  chmod -R u+w "$_t"
done < "$TARGETS_FILE"
