# sw — bidirectional git-sync ~/git/unix, then rebuild the Nix config.
# Exists because `switch` is a fish RESERVED WORD (the switch/case builtin —
# fish will never execute a command by that name from the prompt) and `up`
# spent months shadowed by a stale `alias up` in config.local.fish. sw is a
# real binary on PATH via writeShellScriptBin — no fish function or alias
# machinery involved, nothing to shadow it.
REPO="$HOME/git/unix"

if [ -x "$REPO/1_workflows/dist/scripts/cloud-git-sync.sh" ]; then
  # 6-step engine: stash → fetch → rebase → PUSH → pop → submodules
  git -C "$REPO" sync || echo "[sw] WARN: git sync failed — switching with the tree as-is"
else
  echo "[sw] note: sync engine not present yet — plain pull --rebase"
  git -C "$REPO" pull --rebase || echo "[sw] WARN: pull failed — switching with the tree as-is"
fi

exec "$REPO/bb_flakes_termux/build.sh" switch "$@"
