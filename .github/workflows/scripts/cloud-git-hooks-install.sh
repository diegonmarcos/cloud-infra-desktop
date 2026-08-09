#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-git-hooks-install.sh
# ║   Engine : 1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-git-hooks-install.sh — one hook set, every repo             ║
# ║                                                                  ║
# ║ Installs the shared git hooks (pre-push = the `git sync` engine)  ║
# ║ into every repo listed in data/git-hook-repos.json:               ║
# ║   unix · cloud · cloud-data · cloud-data-lfs · front ·            ║
# ║   front-data · vault · notes                                      ║
# ║                                                                  ║
# ║ Mechanism: hooks + the sync engine are COPIED once into a shared  ║
# ║ dir (~/.config/git/cloud-hooks/{hooks,scripts}), then each repo's ║
# ║ core.hooksPath is pointed at that hooks/ dir and its `sync` alias ║
# ║ declared. One copy to update, N repos following it — no per-repo  ║
# ║ .git/hooks/ duplicates to drift.                                  ║
# ║                                                                  ║
# ║   cloud-git-hooks-install.sh          # install/refresh everywhere║
# ║   cloud-git-hooks-install.sh --check  # report only, change nothing║
# ║                                                                  ║
# ║ Idempotent. A missing repo is reported and skipped, never fatal.  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"                    # …/1_workflows/dist
CFG="${GIT_HOOK_REPOS_JSON:-$DIST/data/git-hook-repos.json}"
[ -f "$CFG" ] || CFG="$HERE/../../src/data/git-hook-repos.json"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

if [ ! -f "$CFG" ]; then
  echo "cloud-git-hooks-install: repo list not found ($CFG)" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "cloud-git-hooks-install: jq required" >&2; exit 1; }

SHARED_REL="$(jq -r '.shared_hooks_dir' "$CFG")"
SHARED="$HOME/$SHARED_REL"
SHARED_HOOKS="$SHARED/hooks"
SHARED_SCRIPTS="$SHARED/scripts"

# ── 1. populate the shared dir from dist/ ───────────────────────────
if [ "$CHECK" = 0 ]; then
  mkdir -p "$SHARED_HOOKS" "$SHARED_SCRIPTS"
  for h in "$DIST/hooks"/*; do
    [ -f "$h" ] || continue
    install -m 0755 "$h" "$SHARED_HOOKS/$(basename "$h")"
  done
  # The pre-push hook resolves ../scripts/cloud-git-sync.sh relative to
  # itself — that is why the engine ships beside the hooks.
  for s in "$DIST/scripts"/*.sh; do
    [ -f "$s" ] || continue
    install -m 0755 "$s" "$SHARED_SCRIPTS/$(basename "$s")"
  done
  echo "shared hooks : $SHARED_HOOKS  ($(ls -1 "$SHARED_HOOKS" | wc -l | tr -d ' ') hooks)"
fi

# ── 2. wire every repo ──────────────────────────────────────────────
ok=0; skipped=0
while IFS=$'\t' read -r name root; do
  [ -n "$name" ] || continue
  case "$root" in /*) dir="$root" ;; *) dir="$HOME/$root" ;; esac

  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    printf '  %-16s SKIP  (not a git repo at %s)\n' "$name" "$dir"
    skipped=$((skipped + 1))
    continue
  fi

  current="$(git -C "$dir" config --local --get core.hooksPath 2>/dev/null || true)"
  if [ "$CHECK" = 1 ]; then
    if [ "$current" = "$SHARED_HOOKS" ]; then
      printf '  %-16s ok    (hooksPath → shared)\n' "$name"
    else
      printf '  %-16s DRIFT (hooksPath = %s)\n' "$name" "${current:-<unset>}"
    fi
    continue
  fi

  git -C "$dir" config --local core.hooksPath "$SHARED_HOOKS"
  # `git sync` everywhere, pointing at the shared engine (repos other than
  # unix have no 1_workflows/ of their own).
  git -C "$dir" config --local alias.sync "!$SHARED_SCRIPTS/cloud-git-sync.sh"
  printf '  %-16s wired (hooksPath + sync alias)\n' "$name"
  ok=$((ok + 1))
done < <(jq -r '.repos[] | [.name, .root] | @tsv' "$CFG")

[ "$CHECK" = 1 ] && exit 0
echo "wired $ok repo(s), skipped $skipped"
echo "verify: cloud-git-hooks-install.sh --check"
