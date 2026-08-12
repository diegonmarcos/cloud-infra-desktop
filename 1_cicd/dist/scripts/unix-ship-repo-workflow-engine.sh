#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Engine : 1_cicd/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Workflow engine: build (src→dist) + deploy (dist→.github/)       ║
# ║                                                                  ║
# ║ Usage: ./build.sh              # build + deploy (default)        ║
# ║        ./build.sh build        # src → dist only                 ║
# ║        ./build.sh deploy       # dist → .github/ + repo root    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e
chmod +x "$0"

# Prefer termux coreutils over nix cp, which fails with libpthread on Android.
export PATH="/data/data/com.termux.nix/files/usr/bin:$PATH"

# Repo root by upward search for .git, NOT by counting ../ from $0. This engine
# is reached through a symlink (9_others/build.sh) whose real path sits three
# levels down in 1_cicd/src/scripts/, so any fixed ../ count is right for one of
# the two ways it gets invoked and silently one level off for the other.
REPO_ROOT="${UNIX_ROOT:-$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")}"

# Config tiers. Each owns its own dist/, so a source and its compiled form sit
# together instead of every artifact landing in one flat 1_configs/dist.
GIT_SRC="$REPO_ROOT/0_git/src";     GIT_DIST="$REPO_ROOT/0_git/dist"
APPS_SRC="$REPO_ROOT/0_apps/src";   APPS_DIST="$REPO_ROOT/0_apps/dist"
CICD_SRC="$REPO_ROOT/1_cicd/src";   CICD_DIST="$REPO_ROOT/1_cicd/dist"
LIB_SRC="$REPO_ROOT/9_others/src";  LIB_DIST="$REPO_ROOT/9_others/dist"
TARGET_DIR="$REPO_ROOT/.github/workflows"
SCRIPTS_TARGET="$TARGET_DIR/scripts"
HOOKS_TARGET="$TARGET_DIR/hooks"

# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
# Template + prefix map live in $LIB_SRC/generated-header.json.
export REPO_ROOT
export ENGINE_NAME="1_cicd/src/scripts/unix-ship-repo-workflow-engine.sh"
# shellcheck source=../../lib/inject-header.sh
. "$LIB_SRC/inject-header.sh"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

do_build() {
    # Clean dist/ first so deletions in src/ propagate (otherwise orphaned
    # scripts/hooks linger forever, including broken symlinks).
    rm -rf "$CICD_DIST" "$GIT_DIST" "$LIB_DIST"
    mkdir -p "$CICD_DIST" "$CICD_DIST/scripts" "$GIT_DIST/hooks" "$LIB_DIST/test"

    # Static workflows (src/cicd/*.yml + *.yaml → dist/)
    # A glob that matches nothing is silent in sh: the loop never runs, deploy
    # copies zero files, and the already-deployed .github/ copies sit there
    # looking healthy. That is exactly how cloud rendered 0 workflows for a
    # week after its cicd/ moved (2026-08-10). Fail loudly instead.
    if ! ls "$CICD_SRC"/cicd/*.yml "$CICD_SRC"/cicd/*.yaml >/dev/null 2>&1; then
        echo "FATAL: no workflows found at $CICD_SRC/cicd/*.{yml,yaml}" >&2
        exit 1
    fi
    for f in "$CICD_SRC"/cicd/*.yml "$CICD_SRC"/cicd/*.yaml; do
        [ -f "$f" ] || continue
        inject_header "$f" "$CICD_DIST/$(basename "$f")"
    done
    log "Built $(ls "$CICD_DIST"/*.yml "$CICD_DIST"/*.yaml 2>/dev/null | wc -l) workflow(s)"

    # Scripts (src/scripts/ → dist/scripts/)
    if [ -d "$CICD_SRC/scripts" ]; then
        inject_header_tree "$CICD_SRC/scripts" "$CICD_DIST/scripts"
        log "Built scripts"
    fi

    # Hooks (src/hooks/ → dist/hooks/)
    if [ -d "$GIT_SRC/hooks" ]; then
        inject_header_tree "$GIT_SRC/hooks" "$GIT_DIST/hooks"
        log "Built hooks"
    fi

    # Data (src/data/ → dist/data/) — JSON the scripts read at runtime, e.g.
    # git-hook-repos.json (which repos get the shared hooks). Copied verbatim:
    # the header injector would corrupt JSON.
    if [ -d "$LIB_SRC/data" ]; then
        mkdir -p "$LIB_DIST/data"
        cp -f "$LIB_SRC/data"/*.json "$LIB_DIST/data/" 2>/dev/null || true
        log "Built data"
    fi

    # Tests (src/test/ → dist/test/) — preflight testers invoked by ship-ci-image.yml
    if [ -d "$REPO_ROOT/9_others/test" ]; then
        inject_header_tree "$REPO_ROOT/9_others/test" "$LIB_DIST/test"
        log "Built tests"
    fi

    # Gitmodules (src/modules/gitmodules → dist/.gitmodules)
    if [ -f "$GIT_SRC/gitmodules" ]; then
        inject_header "$GIT_SRC/gitmodules" "$GIT_DIST/.gitmodules"
        log "Built gitmodules"
    fi

    # Gitignore (src/gitignore → dist/.gitignore)
    if [ -f "$GIT_SRC/gitignore" ]; then
        inject_header "$GIT_SRC/gitignore" "$GIT_DIST/.gitignore"
        log "Built gitignore"
    fi

    # Gitattributes (src/gitattributes → dist/.gitattributes)
    if [ -f "$GIT_SRC/gitattributes" ]; then
        inject_header "$GIT_SRC/gitattributes" "$GIT_DIST/.gitattributes"
        log "Built gitattributes"
    fi

    # Gitconfig (src/gitconfig → dist/)
    if [ -f "$GIT_SRC/gitconfig" ]; then
        inject_header "$GIT_SRC/gitconfig" "$GIT_DIST/gitconfig"
        log "Built gitconfig"
    fi

    # LICENSE is copied VERBATIM — no generated banner. GitHub's licence
    # detector and SPDX scanners match on the text, and a banner breaks them.
    if [ -f "$GIT_SRC/LICENSE" ]; then
        cp -f "$GIT_SRC/LICENSE" "$GIT_DIST/LICENSE"
        log "Built LICENSE (verbatim)"
    fi

    # GHA actions (src/actions/ → dist/actions/)
    if [ -d "$CICD_SRC/actions" ]; then
        inject_header_tree "$CICD_SRC/actions" "$CICD_DIST/actions"
        log "Built actions"
    fi

    # GHA flake (src/flake.nix, src/flake.lock → dist/)
    # flake.lock is in skip_basenames (inject-header.sh) → copied verbatim.
    if [ -f "$CICD_SRC/flake.nix" ]; then
        inject_header "$CICD_SRC/flake.nix" "$CICD_DIST/flake.nix"
        log "Built flake.nix"
    fi
    if [ -f "$CICD_SRC/flake.lock" ]; then
        inject_header "$CICD_SRC/flake.lock" "$CICD_DIST/flake.lock"
        log "Built flake.lock"
    fi
}

do_deploy() {
    mkdir -p "$TARGET_DIR" "$SCRIPTS_TARGET" "$HOOKS_TARGET"

    # Workflows
    for f in "$CICD_DIST"/*.yml "$CICD_DIST"/*.yaml; do
        [ -f "$f" ] || continue
        cp "$f" "$TARGET_DIR/"
    done
    log "Deployed $(ls "$CICD_DIST"/*.yml "$CICD_DIST"/*.yaml 2>/dev/null | wc -l) workflow(s) → .github/workflows/"

    # Remove workflows whose source is gone. Deploy was copy-only, so a
    # workflow deleted from src/ stayed in .github/ forever — and GitHub keeps
    # RUNNING it on schedule. It also let hand-written files survive there with
    # no source at all; five did in this repo and were promoted into src/.
    _orphans=0
    for f in "$TARGET_DIR"/*.yml "$TARGET_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        [ -f "$CICD_DIST/$(basename "$f")" ] && continue
        log "Removing orphan workflow $(basename "$f") — no source in src/gha/cicd/"
        rm -f "$f"
        _orphans=$((_orphans+1))
    done
    [ "$_orphans" -gt 0 ] && log "Removed $_orphans orphan workflow(s)"

    # Scripts
    if [ -d "$CICD_DIST/scripts" ]; then
        cp -r "$CICD_DIST/scripts/"* "$SCRIPTS_TARGET/" 2>/dev/null || true
        chmod +x "$SCRIPTS_TARGET/"*.sh 2>/dev/null || true
        log "Deployed scripts"
    fi

    # Hooks
    if [ -d "$GIT_DIST/hooks" ]; then
        cp -r "$GIT_DIST/hooks/"* "$HOOKS_TARGET/" 2>/dev/null || true
        chmod +x "$HOOKS_TARGET/"*.sh 2>/dev/null || true
        log "Deployed hooks"
    fi

    # GHA actions (dist/actions/ → .github/actions/)
    if [ -d "$CICD_DIST/actions" ]; then
        mkdir -p "$REPO_ROOT/.github/actions"
        cp -r "$CICD_DIST/actions/"* "$REPO_ROOT/.github/actions/" 2>/dev/null || true
        log "Deployed actions → .github/actions/"
    fi

    # GHA flake (dist/flake.{nix,lock} → .github/)
    for f in flake.nix flake.lock; do
        if [ -f "$CICD_DIST/$f" ]; then
            cp "$CICD_DIST/$f" "$REPO_ROOT/.github/$f"
            log "Deployed $f → .github/"
        fi
    done

    # Repo-root configs (.gitmodules etc). gitconfig is deliberately NOT here:
    # the glob is .git* and gitconfig has no dot, because it is included from
    # .git/config rather than read out of the working tree.
    for f in "$GIT_DIST"/.git*; do
        [ -f "$f" ] || continue
        cp "$f" "$REPO_ROOT/"
        log "Deployed $(basename "$f") → repo root"
    done

    # LICENSE is a git-tier file like the rest, so it is generated from
    # 0_git/src rather than hand-edited at the root.
    if [ -f "$GIT_DIST/LICENSE" ]; then
        cp -f "$GIT_DIST/LICENSE" "$REPO_ROOT/LICENSE"
        log "Deployed LICENSE → repo root"
    fi

    # Sync submodules: ensure all entries in .gitmodules are registered + cloned
    if [ -f "$REPO_ROOT/.gitmodules" ]; then
        # Build the declared-paths set from .gitmodules first so we can
        # detect + purge stale gitlinks (mode 160000 in the index that
        # don't correspond to any current declaration — typically left
        # over from a submodule path rename like front-data → III_front-data).
        declared_paths=$(git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null \
            | awk '{print $2}' | sort -u)
        # Scan the index for every gitlink; remove any whose path isn't
        # declared. Use `git rm --cached` so the on-disk dir (if any)
        # stays for separate cleanup by the user.
        git -C "$REPO_ROOT" ls-files --stage 2>/dev/null \
            | awk '$1 == "160000" {print $4}' | while read -r idx_path; do
            if ! echo "$declared_paths" | grep -qx "$idx_path"; then
                log "submodule purge: removing stale gitlink '$idx_path' (not declared in .gitmodules)"
                git -C "$REPO_ROOT" rm --cached "$idx_path" 2>&1 | while IFS= read -r line; do log "  $line"; done
            fi
        done
        # Read declared submodules from .gitmodules
        git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r key path; do
            name=$(echo "$key" | sed 's/^submodule\.\(.*\)\.path$/\1/')
            url=$(git -C "$REPO_ROOT" config --file .gitmodules "submodule.$name.url" 2>/dev/null || true)
            # Check if submodule is already in git index
            if git -C "$REPO_ROOT" ls-files --stage "$path" 2>/dev/null | grep -q '^160000'; then
                log "submodule '$name' already registered"
            else
                # New submodule: add it (this registers gitlink + clones)
                log "submodule '$name' not in index — adding from .gitmodules"
                git -C "$REPO_ROOT" submodule add --force --name "$name" "$url" "$path" 2>&1 | while IFS= read -r line; do
                    log "  $line"
                done
            fi
        done
        # Recover broken gitdirs: when a submodule's path/.git file points
        # at a missing .git/modules/<name>/ cache (e.g. an alias collision
        # from a stale rename), `submodule update --init` silently skips
        # it. Detect + force-reinit so the cache is rebuilt declaratively.
        git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r key path; do
            name=$(echo "$key" | sed 's/^submodule\.\(.*\)\.path$/\1/')
            gitdir_pointer="$REPO_ROOT/$path/.git"
            [ -e "$gitdir_pointer" ] || continue
            # If it's a regular file (worktree pointer), resolve it.
            if [ -f "$gitdir_pointer" ]; then
                target=$(sed -n 's/^gitdir: //p' "$gitdir_pointer" | head -1)
                # Resolve relative path against parent of pointer.
                case "$target" in
                    /*) abs_target="$target" ;;
                    *)  abs_target="$REPO_ROOT/$path/$target" ;;
                esac
                if [ ! -d "$abs_target" ]; then
                    log "submodule '$name' has broken gitdir ($target) — reinitialising"
                    git -C "$REPO_ROOT" submodule deinit -f "$path" 2>&1 | while IFS= read -r line; do log "  deinit: $line"; done
                    git -C "$REPO_ROOT" submodule update --init --force "$path" 2>&1 | while IFS= read -r line; do log "  reinit: $line"; done
                fi
            fi
        done
        # Sync URLs + update all
        git -C "$REPO_ROOT" submodule sync 2>/dev/null || true
        git -C "$REPO_ROOT" submodule update --init 2>&1 | while IFS= read -r line; do
            log "submodule: $line"
        done
        log "Synced submodules"
    fi

    # Gitconfig → include in .git/config
    # Reconcile: unset any local keys owned by dist/gitconfig so they cannot
    # shadow the declared config (last-wins makes post-include entries win).
    if [ -f "$GIT_DIST/gitconfig" ]; then
        _gc_section=""
        while IFS= read -r line; do
            case "$line" in
                \[*\])
                    _gc_section=$(printf '%s' "$line" | sed 's/^\[\([^]]*\)\]$/\1/' | tr '[:upper:]' '[:lower:]')
                    ;;
                *=*)
                    [ -z "$_gc_section" ] && continue
                    _gc_key=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\([a-zA-Z][a-zA-Z0-9]*\)[[:space:]]*=.*/\1/p' | tr '[:upper:]' '[:lower:]')
                    [ -n "$_gc_key" ] && git -C "$REPO_ROOT" config --local --unset "${_gc_section}.${_gc_key}" 2>/dev/null || true
                    ;;
            esac
        done < "$GIT_DIST/gitconfig"
        unset _gc_section _gc_key
        git -C "$REPO_ROOT" config --local include.path ../0_git/dist/gitconfig 2>/dev/null || true
        log "Deployed gitconfig (included in .git/config)"
    fi

    log "Done"
}

# ── dotfiles ────────────────────────────────────────────────────────────────
# src/apps/<tool>/ → dist/dotfiles/<tool>/ → <repo>/<target>/
# Was its own 2_configs module; folded in so a repo carries ONE config module.
# Never purge-then-copy: .claude/ and .obsidian/ mix managed config with
# per-machine state (pane layout, local overrides).
do_dotfiles() {
    [ -d "$APPS_SRC" ] || { log "no 0_apps/src — skipping dotfiles"; return 0; }
    sh "$LIB_SRC/deploy-dotfiles.sh" "$APPS_SRC" "$APPS_DIST/dotfiles" "$REPO_ROOT"
}

case "${1:-all}" in
    build)    do_build ;;
    deploy)   do_deploy ;;
    dotfiles) do_dotfiles ;;
    all|"")   do_build; do_deploy; do_dotfiles ;;
    *)        echo "Usage: $0 [build|deploy|dotfiles|all]" ;;
esac
