echo "Claude Rescue — fallback chain"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export TERM="${TERM:-xterm-256color}"
# 1) Podman
if command -v podman >/dev/null 2>&1; then
  echo "[1/4] Trying podman..."
  timeout 60 podman run --rm -it \
    --name claude-rescue \
    -v "$HOME:/host-home:ro" \
    -e ANTHROPIC_API_KEY -e TERM \
    --user root \
    node:22-slim \
    sh -c 'npm install -g @anthropic-ai/claude-code 2>/dev/null && claude "$@"' -- "$@" \
    && exit 0
  echo "[1/4] podman failed, trying next..."
fi
# 2) npx
if command -v npx >/dev/null 2>&1; then
  echo "[2/4] Trying npx..."
  npx -y @anthropic-ai/claude-code "$@" && exit 0
  echo "[2/4] npx failed, trying next..."
fi
# 3) Nix shell
if command -v nix >/dev/null 2>&1; then
  echo "[3/4] Trying nix shell..."
  timeout 120 nix shell nixpkgs#nodejs_22 --command sh -c \
    'npx -y @anthropic-ai/claude-code "$@"' -- "$@" \
    && exit 0
  echo "[3/4] nix shell failed, trying next..."
fi
# 4) Raw node
if command -v node >/dev/null 2>&1; then
  echo "[4/4] Trying raw node bootstrap..."
  _tmp=$(mktemp -d)
  cd "$_tmp" || exit 1
  npm init -y >/dev/null 2>&1 && npm install @anthropic-ai/claude-code >/dev/null 2>&1
  ./node_modules/.bin/claude "$@" && exit 0
fi
echo "ALL METHODS FAILED"
exit 1
