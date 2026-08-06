#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Engine : 1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"
TARGET_DIR="$REPO_ROOT/.github/workflows"
SCRIPTS_TARGET="$TARGET_DIR/scripts"
HOOKS_TARGET="$TARGET_DIR/hooks"

# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
# Template + prefix map live in $SRC_DIR/libs/generated-header.json.
export REPO_ROOT
export ENGINE_NAME="1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh"
# shellcheck source=../libs/inject-header.sh
. "$SRC_DIR/libs/inject-header.sh"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

do_build() {
    # Clean dist/ first so deletions in src/ propagate (otherwise orphaned
    # scripts/hooks linger forever, including broken symlinks).
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR" "$DIST_DIR/scripts" "$DIST_DIR/hooks" "$DIST_DIR/test"

    # Static workflows (src/cicd/*.yml + *.yaml → dist/)
    for f in "$SRC_DIR"/cicd/*.yml "$SRC_DIR"/cicd/*.yaml; do
        [ -f "$f" ] || continue
        inject_header "$f" "$DIST_DIR/$(basename "$f")"
    done
    log "Built $(ls "$DIST_DIR"/*.yml "$DIST_DIR"/*.yaml 2>/dev/null | wc -l) workflow(s)"

    # Scripts (src/scripts/ → dist/scripts/)
    if [ -d "$SRC_DIR/scripts" ]; then
        inject_header_tree "$SRC_DIR/scripts" "$DIST_DIR/scripts"
        log "Built scripts"
    fi

    # Hooks (src/hooks/ → dist/hooks/)
    if [ -d "$SRC_DIR/hooks" ]; then
        inject_header_tree "$SRC_DIR/hooks" "$DIST_DIR/hooks"
        log "Built hooks"
    fi

    # Tests (src/test/ → dist/test/) — preflight testers invoked by ship-ci-image.yml
    if [ -d "$SRC_DIR/test" ]; then
        inject_header_tree "$SRC_DIR/test" "$DIST_DIR/test"
        log "Built tests"
    fi

    # Gitmodules (src/modules/gitmodules → dist/.gitmodules)
    if [ -f "$SRC_DIR/modules/gitmodules" ]; then
        inject_header "$SRC_DIR/modules/gitmodules" "$DIST_DIR/.gitmodules"
        log "Built gitmodules"
    fi

    # Gitignore (src/gitignore → dist/.gitignore)
    if [ -f "$SRC_DIR/gitignore" ]; then
        inject_header "$SRC_DIR/gitignore" "$DIST_DIR/.gitignore"
        log "Built gitignore"
    fi

    # Gitconfig (src/gitconfig → dist/)
    if [ -f "$SRC_DIR/gitconfig" ]; then
        inject_header "$SRC_DIR/gitconfig" "$DIST_DIR/gitconfig"
        log "Built gitconfig"
    fi

    # GHA actions (src/actions/ → dist/actions/)
    if [ -d "$SRC_DIR/actions" ]; then
        inject_header_tree "$SRC_DIR/actions" "$DIST_DIR/actions"
        log "Built actions"
    fi

    # GHA flake (src/flake.nix, src/flake.lock → dist/)
    # flake.lock is in skip_basenames (inject-header.sh) → copied verbatim.
    if [ -f "$SRC_DIR/flake.nix" ]; then
        inject_header "$SRC_DIR/flake.nix" "$DIST_DIR/flake.nix"
        log "Built flake.nix"
    fi
    if [ -f "$SRC_DIR/flake.lock" ]; then
        inject_header "$SRC_DIR/flake.lock" "$DIST_DIR/flake.lock"
        log "Built flake.lock"
    fi
}

do_deploy() {
    mkdir -p "$TARGET_DIR" "$SCRIPTS_TARGET" "$HOOKS_TARGET"

    # Workflows
    for f in "$DIST_DIR"/*.yml "$DIST_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        cp "$f" "$TARGET_DIR/"
    done
    log "Deployed $(ls "$DIST_DIR"/*.yml "$DIST_DIR"/*.yaml 2>/dev/null | wc -l) workflow(s) → .github/workflows/"

    # Scripts
    if [ -d "$DIST_DIR/scripts" ]; then
        cp -r "$DIST_DIR/scripts/"* "$SCRIPTS_TARGET/" 2>/dev/null || true
        chmod +x "$SCRIPTS_TARGET/"*.sh 2>/dev/null || true
        log "Deployed scripts"
    fi

    # Hooks
    if [ -d "$DIST_DIR/hooks" ]; then
        cp -r "$DIST_DIR/hooks/"* "$HOOKS_TARGET/" 2>/dev/null || true
        chmod +x "$HOOKS_TARGET/"*.sh 2>/dev/null || true
        log "Deployed hooks"
    fi

    # GHA actions (dist/actions/ → .github/actions/)
    if [ -d "$DIST_DIR/actions" ]; then
        mkdir -p "$REPO_ROOT/.github/actions"
        cp -r "$DIST_DIR/actions/"* "$REPO_ROOT/.github/actions/" 2>/dev/null || true
        log "Deployed actions → .github/actions/"
    fi

    # GHA flake (dist/flake.{nix,lock} → .github/)
    for f in flake.nix flake.lock; do
        if [ -f "$DIST_DIR/$f" ]; then
            cp "$DIST_DIR/$f" "$REPO_ROOT/.github/$f"
            log "Deployed $f → .github/"
        fi
    done

    # Repo-root configs (.gitmodules etc)
    for f in "$DIST_DIR"/.git*; do
        [ -f "$f" ] || continue
        cp "$f" "$REPO_ROOT/"
        log "Deployed $(basename "$f") → repo root"
    done

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
    if [ -f "$DIST_DIR/gitconfig" ]; then
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
        done < "$DIST_DIR/gitconfig"
        unset _gc_section _gc_key
        git -C "$REPO_ROOT" config --local include.path ../1_workflows/dist/gitconfig 2>/dev/null || true
        log "Deployed gitconfig (included in .git/config)"
    fi

    log "Done"
}

case "${1:-all}" in
    build)   do_build ;;
    deploy)  do_deploy ;;
    all|"")  do_build; do_deploy ;;
    *)       echo "Usage: $0 [build|deploy|all]" ;;
esac
