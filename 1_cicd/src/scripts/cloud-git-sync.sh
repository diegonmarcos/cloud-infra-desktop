#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-git-sync.sh — smart, verbose, non-destructive `git sync`   ║
# ║                                                                  ║
# ║ Source: cloud/1_cicd/src/scripts/cloud-git-sync.sh          ║
# ║ Wired : 0_git/src/gitconfig  →  [alias] sync               ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   git sync              # default: LOCAL wins on conflict        ║
# ║   git sync ask          # prompt on conflict (local wins, no TTY)║
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
    ask|remote|local) MODE="$arg" ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      printf 'usage: git sync [{ask|local|remote}] [--no-push] [-q|--quiet]\n' >&2
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
# `ask` has no fixed side — STRATEGY stays unset until a conflict actually
# happens (see step 3), at which point the user's choice picks theirs/ours.
if [ "$MODE" = "ask" ]; then
  STRATEGY=""
else
  STRATEGY=$([ "$MODE" = "local" ] && echo theirs || echo ours)
fi

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

rebase_halted() {
  # $1 = one-line description of what was attempted, for the banner.
  banner_err "
╔══════════════════════════════════════════════════════════════════╗
║ REBASE HALTED                                                    ║
║                                                                  ║
║ $1
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
}

# do_rebase LABEL [git-rebase -X args...]
# Runs `git rebase <args> origin/$BRANCH`, sets N_REBASED / prints ok on
# success, halts (rebase_halted, exit 1) on failure. LABEL is cosmetic,
# shown in the ok line and the halt banner; pass "" for none.
do_rebase() {
  _label="$1"; shift
  if git rebase "$@" "origin/$BRANCH"; then
    N_REBASED="$AHEAD_AFTER_FETCH"
    ok "rebased $N_REBASED local commit(s) onto origin/$BRANCH${_label:+ ($_label)}"
  else
    rebase_halted "git rebase $* origin/$BRANCH was not enough — a structural conflict remains."
  fi
}

# read_conflict_choice: prompts on the controlling terminal (never stdin —
# a git hook's stdin carries ref data, so a plain `read` would consume
# garbage) and sets ANSWER. 30s timeout via the `timeout` utility when
# present (this file is #!/bin/sh; `read -t` is a bashism, so we shell out
# to `timeout` rather than switch shebangs — if `timeout` isn't installed
# we fall back to an untimed read rather than hang forever silently, since
# a hook without `timeout` is already an unusual environment). No usable
# /dev/tty at all (CI, scripted push): ANSWER stays empty, no prompt shown.
#
# --foreground is LOAD-BEARING, not a nicety (2026-08-09): GNU `timeout`
# puts the child in its OWN process group unless told otherwise. A process
# group that isn't the terminal's foreground group gets SIGTTIN when it
# reads the tty — so the read stops dead, the prompt sits there ignoring
# every keypress, and 30s later the timeout fires and we "auto-choose
# local". Verified: without --foreground a typed `r` is never seen; with
# it, `r` returns in 0.3s and an unanswered prompt still times out on
# schedule. busybox `timeout` has no --foreground (and no setpgid either,
# so it doesn't need one) — probe once and use the plain form there.
read_conflict_choice() {
  ANSWER=""
  [ -r /dev/tty ] && [ -w /dev/tty ] || return 0
  _prompt='  conflict — [l]ocal wins / [r]emote wins / [m]anual / [s]kip (30s, default l): '
  if command -v timeout >/dev/null 2>&1; then
    if timeout --foreground 1 true 2>/dev/null; then
      set -- timeout --foreground 30
    else
      set -- timeout 30
    fi
    ANSWER=$("$@" sh -c '
      printf %s "$1" > /dev/tty
      read -r a < /dev/tty
      printf %s "$a"
    ' _ "$_prompt" 2>/dev/null) || ANSWER=""
  else
    printf '%s' "$_prompt" > /dev/tty
    read -r ANSWER < /dev/tty || ANSWER=""
  fi
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
case "$MODE" in
  ask)    MODE_DESC="ask (prompt on conflict; local wins if no TTY)" ;;
  *)      MODE_DESC="$MODE (conflict → $MODE wins, rebase -X $STRATEGY)" ;;
esac
kv "mode"            "$MODE_DESC"

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

# ── 0a. stale index.lock ────────────────────────────────────────────
# A run killed between steps 1 and 5 leaves .git/index.lock behind, and every
# later git write then dies with "Another git process seems to be running".
# Twice on 2026-08-09 that lock sat for over an hour and had to be cleared by
# hand. Only remove it when nothing is actually running AND it is old enough
# that no in-flight operation could still own it — deleting a live lock
# corrupts the index, which is far worse than refusing to sync.
GIT_DIR_PATH=$(git rev-parse --git-dir)
LOCK_FILE="$GIT_DIR_PATH/index.lock"
if [ -e "$LOCK_FILE" ]; then
  if pgrep -x git >/dev/null 2>&1; then
    err "a git process is running and holds $LOCK_FILE — aborting"
    exit 1
  fi
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -ge 300 ]; then
    warn "stale index.lock (${LOCK_AGE}s old, no git process) — removing"
    rm -f "$LOCK_FILE"
  else
    err "index.lock is only ${LOCK_AGE}s old — another sync may be starting; aborting"
    exit 1
  fi
fi

# ── 0b. resume a stash stranded by a previous run ───────────────────
# Steps 1..5 are NOT atomic. If the process dies in that window — terminal
# closed, Android killing Termux, phone asleep — the dirty worktree stays in
# the stash and nothing ever comes back for it. Worse, the next run stashes on
# top and buries it: that is how this repo reached 10 stashes, and how a whole
# uncommitted session was stranded on 2026-08-09 (recovered by hand from
# stash@{0}^3).
#
# So adopt a leftover pre-sync stash BEFORE creating a new one. This is the
# backstop for SIGKILL, which no trap can catch.
TOP_STASH_MSG=$(git stash list -1 --format='%gs' 2>/dev/null || true)
case "${SKIP_STASH_RESUME:-}${TOP_STASH_MSG}" in
  1*) : ;;   # escape hatch: SKIP_STASH_RESUME=1 git sync
  *"pre-sync "*)
    section "0b/6 resume stranded stash"
    warn "a previous sync left work behind: $TOP_STASH_MSG"
    # Only pop onto a CLEAN tree. Popping onto dirty work can half-apply and
    # then fail, and the cleanup below would take the user's live edits with
    # it. When dirty, warn and carry on — step 1 stashes on top, which is not
    # ideal, but silently mangling current work is worse.
    if [ "$N_DIRTY" -gt 0 ]; then
      warn "worktree is dirty ($N_DIRTY file(s)) — not resuming now; run 'git sync' again on a clean tree"
      warn "stranded work stays at stash@{0}; $(git stash list --format='%gs' | grep -c 'pre-sync' || true) pre-sync stash(es) are queued"
    else
    step "git stash pop"
    if git stash pop >/dev/null 2>&1; then
      ok "recovered stranded work from stash@{0}"
      # Recount: step 1 must stash the resumed work too, not the stale totals.
      N_STAGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
      N_UNSTAGED=$(git diff --name-only | wc -l | tr -d ' ')
      N_UNTRACKED=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
      N_DIRTY=$((N_STAGED + N_UNSTAGED + N_UNTRACKED))
      kv "dirty (after resume)" "staged=$N_STAGED  unstaged=$N_UNSTAGED  untracked=$N_UNTRACKED  (total=$N_DIRTY)"
    else
      # A failed `git stash pop` leaves the HALF-APPLIED result in the tree
      # (unmerged paths, conflict markers) and keeps the stash. Leaving that
      # behind is the very thing this guard exists to prevent — and it is how
      # six .nix files full of markers reached main once already. The tree was
      # verified clean above, so discarding the partial application restores
      # exactly the pre-pop state and loses nothing: the stash still has it all.
      warn "stranded stash does not apply to the current tree — undoing the partial pop"
      # ORDER MATTERS: `git checkout -- .` refuses to touch an UNMERGED path,
      # so reset the index back to HEAD first to clear the conflict entries,
      # then restore the worktree, then drop files the pop introduced. Doing
      # checkout before reset silently leaves the conflicted file — caught by
      # the test that greps the tree for markers afterwards.
      git reset -q 2>/dev/null || true
      git checkout -- . 2>/dev/null || true
      git ls-files --others --exclude-standard -z | xargs -0 -r rm -f 2>/dev/null || true
      # NOT fatal. This runs from the pre-push hook, so exiting here would block
      # every push until the backlog is triaged. Warn loudly and keep going; the
      # stash stays put and the warning repeats until someone deals with it.
      N_PRESYNC=$(git stash list --format='%gs' | grep -c 'pre-sync' || true)
      warn "left at stash@{0} — $N_PRESYNC pre-sync stash(es) now queued, triage them:"
      warn "  git stash show -p stash@{0}          # what is in it"
      warn "  git checkout stash@{0}^3 -- .        # untracked files only"
      warn "  git stash drop stash@{0}             # once it is confirmed superseded"
    fi
    fi ;;
esac

# ── 0c. nothing to do? then never touch the worktree ────────────────
# The stash existed only to get a clean tree for the rebase. When there is
# nothing to rebase AND nothing to push, stashing is pure risk: steps 1..5 are
# the window where a killed process strands your work, and most syncs (every
# push on an already-current branch, every pre-push hook run) have nothing to
# do at all. Fetch is read-only and never touches the worktree, so it is safe
# to do BEFORE the stash and decide from real numbers.
#
# Runs after 0b on purpose: a stranded stash must be recovered even on a
# no-op sync, otherwise it would sit there forever.
step "git fetch origin --prune (pre-check)"
git fetch origin --prune --quiet 2>/dev/null || warn "fetch failed — continuing with cached refs"
PRE_AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
PRE_BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)
if [ "$PRE_AHEAD" = 0 ] && [ "$PRE_BEHIND" = 0 ]; then
  section "up to date — nothing to sync"
  kv "vs origin/$BRANCH" "ahead=0  behind=0"
  ok "no rebase, no push, worktree untouched ($N_DIRTY dirty file(s) left exactly as they are)"
  exit 0
fi
kv "vs origin/$BRANCH" "ahead=$PRE_AHEAD  behind=$PRE_BEHIND — sync needed"

# ── 1. stash dirty state ────────────────────────────────────────────
STASHED=0
STASH_RESTORED=0
STASH_MSG=""

# Pop on ANY early exit — Ctrl-C, terminal close, or a failing step under
# `set -e`. Covers everything except SIGKILL; 0b above is the backstop for
# that. Without this, an interrupted sync silently leaves the worktree empty
# and the user has no idea their files are in a stash.
restore_stash_on_abort() {
  _rc=$?
  trap - EXIT INT TERM
  if [ "${STASHED:-0}" = 1 ] && [ "${STASH_RESTORED:-0}" = 0 ]; then
    printf '\n[git sync] interrupted — restoring your worktree from stash@{0}\n' >&2
    if git stash pop >/dev/null 2>&1; then
      printf '[git sync] worktree restored\n' >&2
    else
      printf '[git sync] could not pop automatically; your work is SAFE at stash@{0}\n' >&2
    fi
  fi
  exit "$_rc"
}
trap restore_stash_on_abort EXIT INT TERM

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
N_REBASED=0
if [ "$BEHIND_AFTER_FETCH" = 0 ] && [ "$AHEAD_AFTER_FETCH" = 0 ]; then
  step "nothing to rebase"
  ok "already up-to-date — no rebase needed"
elif [ "$MODE" = "ask" ]; then
  # Try a plain rebase first, WITHOUT -X, so a genuine conflict actually
  # surfaces instead of being silently auto-resolved. Success here means
  # there was no conflict at all — no question to ask.
  step "git rebase origin/$BRANCH   (plain — no -X, let a real conflict surface)"
  if git rebase "origin/$BRANCH"; then
    N_REBASED="$AHEAD_AFTER_FETCH"
    ok "rebased $N_REBASED local commit(s) onto origin/$BRANCH — no conflict, no prompt"
  else
    if ! git rebase --abort; then
      err "git rebase --abort failed — repo left mid-rebase, resolve manually"
      exit 1
    fi
    warn "conflict on rebase — asking how to resolve"
    read_conflict_choice
    case "$ANSWER" in
      l|L|"")
        [ -n "$ANSWER" ] || warn "no answer (no TTY, timeout, or blank) — auto-choosing: local wins"
        step "git rebase -X theirs origin/$BRANCH   (local wins)"
        do_rebase "local wins" -X theirs
        ;;
      r|R)
        step "git rebase -X ours origin/$BRANCH   (remote wins)"
        do_rebase "remote wins" -X ours
        ;;
      m|M)
        step "git rebase origin/$BRANCH   (manual — resolve by hand)"
        if git rebase "origin/$BRANCH"; then
          N_REBASED="$AHEAD_AFTER_FETCH"
          ok "rebased $N_REBASED local commit(s) onto origin/$BRANCH"
        else
          rebase_halted "manual resolution requested — resolve the conflict below."
        fi
        ;;
      s|S)
        warn "skip chosen — leaving HEAD un-rebased; the caller's push may now be rejected by origin (that's expected, not a bug)"
        ;;
      *)
        warn "unrecognized answer '$ANSWER' — defaulting to local wins"
        step "git rebase -X theirs origin/$BRANCH   (local wins)"
        do_rebase "local wins" -X theirs
        ;;
    esac
  fi
else
  step "git rebase -X $STRATEGY origin/$BRANCH"
  do_rebase "" -X "$STRATEGY"
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
    # Deliberately leaving the stash in place — mark it handled so the abort
    # trap does not try to pop it a second time on the way out.
    STASH_RESTORED=1
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
  STASH_RESTORED=1
  ok "restored $N_DIRTY file(s) from stash@{0}"
else
  step "no stash to restore — skipped"
fi

# ── 6. submodule sync ───────────────────────────────────────────────
section "6/6 refresh submodules"
if [ -f .gitmodules ]; then
  step "git submodule update --init --recursive --remote --rebase"
  git submodule update --init --recursive --remote --rebase 2>&1 | sed 's/^/  │ /'

  # Sweep orphaned nested-submodule stubs (2026-08-11). When a NESTED
  # submodule fails to clone — which happens on every machine lacking
  # credentials for a private one — git still leaves the mount-point
  # directory behind containing a lone `.git` file whose `gitdir:` points
  # at a .git/modules/... path that was never created. Nothing is tracked
  # under it, it is not in .gitmodules, and it is invisible to the parent
  # repo, but `git status` inside the SUBMODULE reports it as untracked
  # forever. Four of these (cloud-master, Unix, front, front-assets-cdn)
  # accumulated in IV_cloud-configs and tripped the stop-hook's
  # untracked-files check on every run.
  #
  # Only a directory that is ALL of: untracked, containing nothing but a
  # `.git` file, and whose gitdir target does not exist, is removed. A
  # populated or half-populated submodule is never touched — losing real
  # work to a cleanup routine would be far worse than a noisy status.
  _swept=0
  for _sm in $(git submodule --quiet foreach --recursive 'echo "$toplevel/$sm_path"' 2>/dev/null); do
    [ -d "$_sm" ] || continue
    ( cd "$_sm" 2>/dev/null || exit 0
      git status --porcelain 2>/dev/null | sed -n 's/^?? //p' | while IFS= read -r _d; do
        _d="${_d%/}"
        [ -d "$_d" ] || continue
        # exactly one entry, and it is `.git`
        [ "$(ls -A "$_d" 2>/dev/null | wc -l)" = "1" ] || continue
        [ -f "$_d/.git" ] || continue
        _gd=$(sed -n 's/^gitdir: //p' "$_d/.git" 2>/dev/null)
        [ -n "$_gd" ] || continue
        case "$_gd" in /*) _abs="$_gd" ;; *) _abs="$_d/$_gd" ;; esac
        [ -e "$_abs" ] && continue          # real submodule — leave alone
        rm -rf "$_d" && printf '  │ swept orphaned stub: %s (dangling gitdir)\n' "$_d"
      done ) && _swept=$((_swept + 1))
  done

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
