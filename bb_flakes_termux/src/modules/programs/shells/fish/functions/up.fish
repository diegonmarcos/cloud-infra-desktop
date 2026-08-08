# up — git-sync ~/git/unix, then rebuild the Nix config (build.sh switch).
# Sync is stash-safe: local edits are stashed, pull --rebase on the current
# branch's upstream, local commits pushed, stash restored. A failed rebase
# aborts BEFORE the switch so you never build from a half-rebased tree.
# (build.sh switch takes no extra args; use QUIET=1/FORCE_GC=1 env vars.)
set -l repo $HOME/git/unix

if test -d $repo/.git
    echo "[up] git sync → $repo"
    if not git -C $repo fetch --prune 2>/dev/null
        echo "[up] WARN: fetch failed (offline?) — skipping sync, rebuilding anyway"
    else
        # Tracked changes only — untracked files don't block a rebase and
        # plain `git stash push` wouldn't save them anyway (a dirty flag
        # they set would just trigger a bogus stash-pop warning later).
        set -l dirty (git -C $repo status --porcelain --untracked-files=no)
        if test -n "$dirty"
            echo "[up] stashing local changes"
            git -C $repo stash push -m "up-autostash "(date +%Y%m%d-%H%M%S)
        end
        if git -C $repo pull --rebase
            git -C $repo push 2>/dev/null; or echo "[up] note: nothing pushed (no upstream or no local commits)"
        else
            echo "[up] ERROR: rebase failed — aborting sync, NOT switching. Resolve in $repo"
            git -C $repo rebase --abort 2>/dev/null
            if test -n "$dirty"
                git -C $repo stash pop
            end
            return 1
        end
        if test -n "$dirty"
            if not git -C $repo stash pop
                echo "[up] WARN: stash pop conflicted — your edits are safe in 'git stash list'"
            end
        end
    end
else
    echo "[up] WARN: $repo is not a git repo — skipping sync"
end

$HOME/git/unix/bb_flakes_termux/build.sh switch $argv
