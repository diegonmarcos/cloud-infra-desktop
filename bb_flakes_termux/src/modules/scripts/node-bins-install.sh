# node-bins-install — global tsx + wrangler. Env contract: NODEJS_DIR (…/bin).
# Explicit path tests: `command -v` never hit on the minimal activation PATH,
# so tsx reinstalled on EVERY switch. Wrangler still npm-checks the registry
# but only reinstalls on version change (guarded offline).
export PATH="$NODEJS_DIR:$PATH"
if [ ! -x "$HOME/.npm-global/bin/tsx" ] && [ ! -x "$HOME/.node_modules/node_modules/.bin/tsx" ]; then
  "$NODEJS_DIR/npm" install -g tsx --no-audit --no-fund || true
fi
CURRENT=$("$HOME/.npm-global/bin/wrangler" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
LATEST=$(timeout 20 "$NODEJS_DIR/npm" view wrangler version 2>/dev/null || true)
if [ -z "$CURRENT" ] && [ -n "$LATEST" ]; then
  printf "[node-bins] Installing wrangler@%s\n" "$LATEST"
  "$NODEJS_DIR/npm" install -g wrangler --no-audit --no-fund --force --loglevel=error || true
elif [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
  printf "[node-bins] Updating wrangler: %s → %s\n" "$CURRENT" "$LATEST"
  "$NODEJS_DIR/npm" install -g wrangler@latest --no-audit --no-fund --loglevel=error || true
elif [ -n "$CURRENT" ]; then
  printf "[node-bins] wrangler@%s present (registry unreachable or up to date)\n" "$CURRENT"
fi
