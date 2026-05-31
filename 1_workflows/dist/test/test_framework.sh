#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_framework.sh
# ║   Engine : 1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_framework.sh — verify unix's declarative framework is wired correctly
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

echo "=== unix framework conformance ==="

# 1. .git/config contains [include] pointing to dist/gitconfig
git config --local --get include.path 2>/dev/null | grep -q '1_workflows/dist/gitconfig' \
    || fail ".git/config missing [include] for 1_workflows/dist/gitconfig"
pass ".git/config [include] wired"

# 2. hooksPath resolves to 1_workflows/dist/hooks
[ "$(git config core.hooksPath)" = "1_workflows/dist/hooks" ] \
    || fail "core.hooksPath != 1_workflows/dist/hooks (got: $(git config core.hooksPath))"
pass "hooksPath = 1_workflows/dist/hooks"

# 3. alias.sync is defined
git config alias.sync | grep -q 'cloud-git-sync.sh' \
    || fail "alias.sync missing or wrong"
pass "alias.sync defined"

# 4. pre-commit hook exists + executable
[ -x "1_workflows/dist/hooks/pre-commit" ] \
    || fail "dist/hooks/pre-commit missing or not executable"
pass "pre-commit hook deployed + executable"

# 5. No stale .githooks/ at repo root
[ ! -d "$REPO_ROOT/.githooks" ] || fail ".githooks/ still exists at repo root — should be removed"
pass "no stale .githooks/"

# 6. No stale .gitconfig tracked at repo root
git ls-files .gitconfig 2>/dev/null | grep -q '^.gitconfig$' \
    && fail ".gitconfig still tracked at repo root — should be removed"
pass "no stale .gitconfig tracked at root"

# 7. pre-commit is data-driven for submodules (no hardcoded names)
grep -q "git config --file .gitmodules" "1_workflows/dist/hooks/pre-commit" \
    || fail "pre-commit not data-driven for submodules"
pass "pre-commit data-driven for submodules"

# 8. GHA workflows deployed with engine-generated header
for wf in 1_workflows/src/cicd/*.yml; do
    [ -f "$wf" ] || continue
    name="$(basename "$wf")"
    deployed=".github/workflows/$name"
    [ -f "$deployed" ] || fail "$deployed missing (not deployed)"
    grep -q "GENERATED FILE — DO NOT EDIT" "$deployed" \
        || fail "$deployed missing engine-generated header"
    pass "workflow $name deployed with header"
done

echo "=== all checks passed ==="
