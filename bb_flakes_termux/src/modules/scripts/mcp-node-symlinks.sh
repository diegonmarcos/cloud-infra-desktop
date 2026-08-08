# mcp-node-symlinks — symlink shared node_modules into stdio MCP src dirs so
# ESM imports resolve (NODE_PATH only covers CJS require()).
SHARED="$HOME/.node_modules/node_modules"
MCP_DIRS="
  $HOME/git/cloud/a_solutions/bc-obs_c3-specs-docs-mcp/src
  $HOME/git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src
"
for dir in $MCP_DIRS; do
  [ -d "$dir" ] || continue
  target="$dir/node_modules"
  if [ -L "$target" ] || [ -d "$target" ]; then continue; fi
  ln -s "$SHARED" "$target"
  printf "[node-npm-deps] Symlinked %s -> shared node_modules\n" "$target"
done
