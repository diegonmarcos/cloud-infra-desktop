# Pending patches for `diegonmarcos/cloud`

Patches authored here that belong to the **cloud** repo (which hosts
`a_solutions/infra-api_c3-infra-mcp`, the c3-infra-mcp server), but which
could not be pushed from the session that wrote them.

## Why they live here

This monorepo's automation runs with git credentials scoped to
`diegonmarcos/unix`. Reading `cloud` works (it is public), but pushing is
refused by the proxy:

    access denied by the git proxy: diegonmarcos/cloud is not in this
    session's authorized repository set

So the work is committed here as an applyable patch rather than being
lost with the container. Delete a patch once it has landed upstream.

## Applying

    git clone https://github.com/diegonmarcos/cloud.git
    cd cloud
    git am /path/to/unix/1_cicd/src/patches/cloud-repo/0001-*.patch
    git push origin main

Each patch is `git format-patch` output, so `git am` preserves the
message and authorship. Verify it applies before pushing:

    git apply --check 0001-*.patch

## Contents

`0001-c3-infra-mcp-gha-trigger-inputs-repo-rerun-run-logs.patch` carries TWO
commits (apply with `git am`, which preserves both):

1. **Full GHA control** — `repo` on all seven `devops.workflows.*` tools
   (`GH_REPO` was hardcoded to `<owner>/cloud`, so the unix monorepo's
   app/APK workflows were invisible, not merely untriggerable), `inputs`
   and `ref` on `gha_trigger`, plus new `gha_rerun`, `gha_cancel` and
   `gha_run_logs`.

2. **Full GitHub surface** — 31 new `devops.gh.*` tools: PRs, issues,
   releases (incl. assets — which APK a tag carries), artifacts, repo
   metadata, Actions secrets, and a generic `gh api` escape hatch.
   Also fixes a latent hang in the SHARED exec lib (stdin was opened as a
   pipe and never closed, so any child reading stdin blocked until the
   timeout). That file lives in `c3-infra-api` and is symlinked into
   `c3-infra-mcp`, so **redeploy both services together**.

Both typechecked against the real dependency tree: 9 pre-existing errors
before and after, none in the new code. Verified with `git apply --check`
against a pristine clone of current `main`.

### Two things to check after deploying

- **The `gh` token on the host bounds everything.** Widening the tool
  surface does not widen the credential — if that token lacks `workflow`
  scope or cannot see `diegonmarcos/unix`, the new `repo` parameters
  return "not found" rather than acting.
- **Destructive tools require `confirm=true`** (pr_merge, pr_close,
  issue_close, release_delete, secret_delete, any non-GET `api`). These sit
  behind one bearer token valid until 2036 alongside `devops.docker.exec`
  and `devops.vm.reset`; the flag makes intent explicit.
