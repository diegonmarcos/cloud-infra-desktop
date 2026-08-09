#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-git-sync.sh
# ║   Engine : 1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-git-sync.sh — smart, verbose, non-destructive `git sync`   ║
# ║                                                                  ║
# ║ Source: cloud/1_workflows/src/scripts/cloud-git-sync.sh          ║
# ║ Wired : 1_workflows/src/gitconfig  →  [alias] sync               ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   git sync              # default: LOCAL wins on conflict        ║
# ║   git sync local        # local commits win on conflict          ║
# ║   git sync remote       # origin/main wins on conflict           ║
# ║   git sync --no-push    # sync only, skip step 4 (pre-push hook) ║
# ║   git sync -q|--quiet   # minimal output (overrides default)     ║
# ║                                                                  ║
# ║ Flow:                                                            ║
# ║   0. scan & print pre-sync state (dirty counts, ahead/behind,    ║
# ║      per-submodule drift)                                        ║
# ║   1. stash any dirty work (autosaved, named + timestamped)       ║
# ║   2. fetch origin                                                ║
# ║   3. rebase onto origin/main with -X theirs|ours                 ║
# ║   4. push local commits to origin (sync is BIDIRECTIONAL —       ║
# ║      non-fatal if rejected, commits stay local)                  ║
# ║   5. pop stash                                                   ║
# ║   6. submodule update --init --recursive --remote --rebase       ║
# ║   7. print post-sync summary (old→new SHAs, commits applied,     ║
# ║      pushed count, submodule bumps, timings)                     ║
# ║                                                                  ║
# ║ On any rebase / stash-pop halt, repo is left in a resumable      ║
# ║ state with a recovery banner printed to stderr.                  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

# ── arg parse ───────────────────────────────────────────────────────
QUIET=0
MODE=""
NO_PUSH="${CLOUD_GIT_SYNC_NO_PUSH:-0}"
for arg in "$@"; do
  case "$arg" in
    -q|--quiet) QUIET=1 ;;
    --no-push)  NO_PUSH=1 ;;
    remote|local) MODE="$arg" ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      printf 'usage: git sync [{local|remote}] [--no-push] [-q|--quiet]\n' >&2
      exit 2 ;;
  esac
done
# DEFAULT = local wins (2026-08-08): this repo's own commits are the source
# of truth when you sync; taking origin's side silently discards work you
# just did on the device.
MODE="${MODE:-local}"
# ── rebase -X SIDES ARE SWAPPED vs merge (git-rebase(1): "the side reported
# as ours is the so-far rebased series, starting with <upstream>, and theirs
# is the working branch"). So during `rebase origin/main`:
#     -X theirs → YOUR LOCAL commits win
#     -X ours   → ORIGIN wins
# The old mapping had this exactly backwards (remote→theirs), so `git sync`
# has been doing LOCAL-wins while announcing "remote wins", and `git sync
# local` did remote-wins. Verified empirically 2026-08-08 before flipping.
STRATEGY=$([ "$MODE" = "local" ] && echo theirs || echo ours)

# ── output helpers ──────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_DIM=$(printf '\033[2m')
  C_CYAN=$(printf '\033[36m')
  C_YELLOW=$(printf '\033[33m')
  C_GREEN=$(printf '\033[32m')
  C_RED=$(printf '\033[31m')
else
  C_RESET= C_BOLD= C_DIM= C_CYAN= C_YELLOW= C_GREEN= C_RED=
fi

hr()      { printf '%s────────────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }
section() { printf '\n%s▸ %s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }
step()    { [ "$QUIET" = 1 ] && return; printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
ok()      { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
err()     { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
kv()      { printf '  %-22s %s%s%s\n' "$1" "$C_BOLD" "$2" "$C_RESET"; }

banner_err() {
  printf '%s%s%s\n' "$C_RED" "$1" "$C_RESET" >&2
}

# Marks this process tree as "sync is driving" so the pre-push hook (which
# runs the same engine) doesn't re-enter itself during step 4's push.
export CLOUD_GIT_SYNC_ACTIVE=1

T_START=$(date +%s)

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
HEAD_BEFORE=$(git rev-parse HEAD)
HEAD_BEFORE_SHORT=$(git rev-parse --short HEAD)

# ── 0. pre-sync state ───────────────────────────────────────────────
section "pre-sync state"
kv "repo"            "$REPO_NAME"
kv "branch"          "$BRANCH"
kv "HEAD"            "$HEAD_BEFORE_SHORT"
kv "mode"            "$MODE (conflict → $MODE wins, rebase -X $STRATEGY)"

# dirty file counts
N_STAGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
N_UNSTAGED=$(git diff --name-only | wc -l | tr -d ' ')
N_UNTRACKED=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
N_DIRTY=$((N_STAGED + N_UNSTAGED + N_UNTRACKED))
kv "dirty files"     "staged=$N_STAGED  unstaged=$N_UNSTAGED  untracked=$N_UNTRACKED  (total=$N_DIRTY)"

# peek at origin ahead/behind (requires fetch first for accurate numbers; we'll reprint after fetch)
if git rev-parse --quiet --verify "origin/$BRANCH" >/dev/null; then
  AHEAD_BEFORE=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo ?)
  BEHIND_BEFORE=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo ?)
  kv "vs origin/$BRANCH (pre)" "ahead=$AHEAD_BEFORE  behind=$BEHIND_BEFORE  (pre-fetch cache)"
fi

# submodule snapshot
if [ -f .gitmodules ]; then
  step "submodules (pre):"
  git submodule status --recursive 2>/dev/null | awk '
    { prefix=substr($0,1,1); sha=substr($0,2,40); name=$2
      state = (prefix == "+") ? "drifted" : (prefix == "-") ? "not-init" : (prefix == "U") ? "merge-conflict" : "clean"
      printf "    %-40s %s  (%s)\n", name, substr(sha,1,12), state }'
fi

# ── 1. stash dirty state ────────────────────────────────────────────
STASHED=0
STASH_MSG=""
if [ "$N_DIRTY" -gt 0 ]; then
  section "1/6 stash dirty worktree"
  STASH_MSG="pre-sync $(date -u +%FT%TZ)"
  step "git stash push -u -m \"$STASH_MSG\""
  if git stash push -u -m "$STASH_MSG" >/dev/null; then
    STASHED=1
    ok "stashed $N_DIRTY file(s) → stash@{0}  ($STASH_MSG)"
  else
    err "git stash push failed — aborting"
    exit 1
  fi
else
  section "1/6 stash dirty worktree"
  step "clean worktree — skipped"
fi

# ── 2. fetch origin ─────────────────────────────────────────────────
section "2/6 fetch origin"
step "git fetch origin --prune"
git fetch origin --prune
AHEAD_AFTER_FETCH=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
BEHIND_AFTER_FETCH=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)
ok "fetched. local is ahead=$AHEAD_AFTER_FETCH  behind=$BEHIND_AFTER_FETCH of origin/$BRANCH"

# ── 3. rebase ───────────────────────────────────────────────────────
section "3/6 rebase onto origin/$BRANCH"
step "git rebase -X $STRATEGY origin/$BRANCH"
N_REBASED=0
if [ "$BEHIND_AFTER_FETCH" = 0 ] && [ "$AHEAD_AFTER_FETCH" = 0 ]; then
  ok "already up-to-date — no rebase needed"
elif ! git rebase -X "$STRATEGY" "origin/$BRANCH"; then
  banner_err "
╔══════════════════════════════════════════════════════════════════╗
║ REBASE HALTED                                                    ║
║                                                                  ║
║ rebase -X $STRATEGY was not enough — a structural conflict remains.   ║
║ Resolve in-place:                                                ║
║    edit conflicted files    git add <files>                      ║
║    git rebase --continue                                         ║
║                                                                  ║
║ Or abandon the attempt:                                          ║
║    git rebase --abort                                            ║
║                                                                  ║
║ Your stashed dirty work (if any) is at stash@{0}.                ║
╚══════════════════════════════════════════════════════════════════╝"
  exit 1
else
  N_REBASED="$AHEAD_AFTER_FETCH"
  ok "rebased $N_REBASED local commit(s) onto origin/$BRANCH"
fi

# ── 4. push local commits ───────────────────────────────────────────
# Runs BEFORE the stash pop on purpose: once rebased, the commits are
# final — pushing here means they're safe on origin even if the pop
# conflicts and halts the run. Push failure is non-fatal (origin may
# have moved again mid-sync); the commits stay local for the next sync.
section "4/6 push local commits"
N_PUSHED=0
AHEAD_POST=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
if [ "$NO_PUSH" = 1 ]; then
  # pre-push hook path: git is ALREADY pushing — pushing here would recurse.
  step "--no-push set (pre-push hook) — the caller's push carries these $AHEAD_POST commit(s)"
elif [ "$AHEAD_POST" -gt 0 ]; then
  step "git push origin $BRANCH"
  if git push origin "$BRANCH" >/dev/null 2>&1; then
    N_PUSHED="$AHEAD_POST"
    ok "pushed $N_PUSHED commit(s) → origin/$BRANCH"
  else
    warn "push rejected (origin moved mid-sync, or auth) — commits kept local; re-run git sync"
  fi
else
  step "nothing to push — origin/$BRANCH already has HEAD"
fi

# ── 5. pop stash ────────────────────────────────────────────────────
section "5/6 restore dirty worktree"
if [ "$STASHED" = 1 ]; then
  step "git stash pop"
  if ! git stash pop >/dev/null; then
    banner_err "
╔══════════════════════════════════════════════════════════════════╗
║ STASH POP CONFLICT                                               ║
║                                                                  ║
║ Dirty work from before sync conflicts with rebased tree.         ║
║ Stash preserved at stash@{0}. Resolve manually:                  ║
║    git checkout --theirs <file>   (keep rebased version)         ║
║    git checkout --ours <file>     (keep stashed version)         ║
║    git add <file> && git stash drop stash@{0}                    ║
╚══════════════════════════════════════════════════════════════════╝"
    exit 1
  fi
  ok "restored $N_DIRTY file(s) from stash@{0}"
else
  step "no stash to restore — skipped"
fi

# ── 6. submodule sync ───────────────────────────────────────────────
section "6/6 refresh submodules"
if [ -f .gitmodules ]; then
  step "git submodule update --init --recursive --remote --rebase"
  git submodule update --init --recursive --remote --rebase 2>&1 | sed 's/^/  │ /'
  ok "submodules refreshed"
else
  step "no .gitmodules in this repo — skipped"
fi

# ── post-sync summary ───────────────────────────────────────────────
HEAD_AFTER=$(git rev-parse HEAD)
HEAD_AFTER_SHORT=$(git rev-parse --short HEAD)
T_END=$(date +%s)
ELAPSED=$((T_END - T_START))

section "summary"
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
  kv "HEAD"              "$HEAD_BEFORE_SHORT  (unchanged)"
else
  kv "HEAD"              "$HEAD_BEFORE_SHORT → $HEAD_AFTER_SHORT"
  N_APPLIED=$(git rev-list --count "$HEAD_BEFORE..$HEAD_AFTER" 2>/dev/null || echo ?)
  kv "new commits"       "$N_APPLIED"
fi
kv "pushed"            "$N_PUSHED commit(s) → origin/$BRANCH"
kv "dirty preserved"   "$N_DIRTY file(s)$([ $STASHED = 1 ] && echo '  (via stash, restored)')"
if [ -f .gitmodules ]; then
  SM_DRIFTED=$(git submodule status --recursive 2>/dev/null | grep -c '^+' || true)
  SM_CLEAN=$(git submodule status --recursive 2>/dev/null | grep -c '^ ' || true)
  kv "submodules"        "clean=$SM_CLEAN  drifted=$SM_DRIFTED"
fi
REMAINING_STASH=$(git stash list | wc -l | tr -d ' ')
kv "stash entries left" "$REMAINING_STASH"
kv "elapsed"           "${ELAPSED}s"
hr
printf '%s✓ sync complete%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
