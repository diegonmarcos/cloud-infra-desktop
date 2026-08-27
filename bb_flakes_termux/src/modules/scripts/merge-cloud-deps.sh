# merge-cloud-deps — extract node deps from the cloud repo's generated build
# JSON into .cloud-deps-merged.json. Env contract: NODEJS_DIR.
CLOUD_BUILD=""
for _p in \
    "$HOME/git/cloud-infra-desktop/bb_flakes_termux/build-flakes_termux.json" \
    "$HOME/git/cloud-infra/1_cloud-configs/dist/build-flakes_termux.json"; do
  if [ -f "$_p" ]; then CLOUD_BUILD="$_p"; break; fi
done
CLOUD_OUT="$HOME/.node_modules/.cloud-deps-merged.json"
mkdir -p "$HOME/.node_modules"
if [ -n "$CLOUD_BUILD" ]; then
  PATH="$NODEJS_DIR:$PATH" CLOUD_BUILD="$CLOUD_BUILD" CLOUD_OUT="$CLOUD_OUT" "$NODEJS_DIR/node" -e "
    const fs = require('fs');
    const deps = {};
    try {
      const raw = JSON.parse(fs.readFileSync(process.env.CLOUD_BUILD, 'utf8'));
      const d = raw.deps || raw;
      const take = (obj) => {
        for (const [k, v] of Object.entries(obj || {})) {
          if (!deps[k] || v > deps[k]) deps[k] = v;
        }
      };
      take(d.node?.merged?.dependencies);
      take(d.node?.merged?.devDependencies);
    } catch (e) { console.error('WARN: cloud-deps: ' + e.message); }
    fs.writeFileSync(process.env.CLOUD_OUT, JSON.stringify(deps, null, 2) + '\n');
    console.log('[node-npm-deps-cloud] ' + Object.keys(deps).length + ' cloud deps from ' + process.env.CLOUD_BUILD);
  " || printf "[node-npm-deps-cloud] WARN: merge failed\n"
else
  printf "[node-npm-deps-cloud] No build-flakes_termux.json or cloud-data-deps.json found\n"
  echo '{}' > "$CLOUD_OUT" 2>/dev/null || true
fi
