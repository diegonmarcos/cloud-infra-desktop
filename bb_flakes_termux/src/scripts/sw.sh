# sw — git sync LOCAL (bidirectional: rebase local-wins + push) on
# ~/git/unix, then rebuild the Nix config. Same two steps as the fish
# function `flakes.switch`, which calls this binary.
# Exists because `switch` is a fish RESERVED WORD (the switch/case builtin —
# fish will never execute a command by that name from the prompt) and `up`
# spent months shadowed by a stale `alias up` in config.local.fish. sw is a
# real binary on PATH via writeShellScriptBin — no fish function or alias
# machinery involved, nothing to shadow it.
REPO="$HOME/git/unix"

if [ -x "$REPO/1_workflows/dist/scripts/cloud-git-sync.sh" ]; then
  # 6-step engine: stash → fetch → rebase → PUSH → pop → submodules.
  # Run the SCRIPT directly — the `git sync` alias only exists where the
  # imperative gitconfig include was installed; calling the alias here
  # silently no-op'd on fresh installs ("not a git command" swallowed by
  # the WARN — found in the 2026-08-08 audit).
  ( cd "$REPO" && ./1_workflows/dist/scripts/cloud-git-sync.sh local ) \
    || echo "[sw] WARN: git sync failed — switching with the tree as-is"
else
  echo "[sw] note: sync engine not present yet — plain pull --rebase"
  git -C "$REPO" pull --rebase || echo "[sw] WARN: pull failed — switching with the tree as-is"
fi

exec "$REPO/bb_flakes_termux/build.sh" switch "$@"
