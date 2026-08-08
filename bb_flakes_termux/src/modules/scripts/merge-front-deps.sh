# merge-front-deps — extract node deps from front-data/front-deps.json.
# Env contract: NODEJS_DIR.
FRONT_DEPS="$HOME/git/front/front-data/front-deps.json"
FRONT_OUT="$HOME/.node_modules/.front-deps-merged.json"
mkdir -p "$HOME/.node_modules"
if [ -f "$FRONT_DEPS" ]; then
  PATH="$NODEJS_DIR:$PATH" FRONT_DEPS="$FRONT_DEPS" FRONT_OUT="$FRONT_OUT" "$NODEJS_DIR/node" -e "
    const fs = require('fs');
    const deps = {};
    try {
      const d = JSON.parse(fs.readFileSync(process.env.FRONT_DEPS, 'utf8'));
      const take = (obj) => {
        for (const [k, v] of Object.entries(obj || {})) {
          if (!deps[k] || v > deps[k]) deps[k] = v;
        }
      };
      take(d.node?.merged?.dependencies);
      take(d.node?.merged?.devDependencies);
    } catch (e) { console.error('WARN: front-deps: ' + e.message); }
    fs.writeFileSync(process.env.FRONT_OUT, JSON.stringify(deps, null, 2) + '\n');
    console.log('[node-npm-deps-front] ' + Object.keys(deps).length + ' front deps extracted');
  " || printf "[node-npm-deps-front] WARN: merge failed\n"
else
  printf "[node-npm-deps-front] No front-deps.json found\n"
  echo '{}' > "$FRONT_OUT" 2>/dev/null || true
fi
