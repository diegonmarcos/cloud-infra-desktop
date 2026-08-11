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
    git am /path/to/unix/1_configs/src/gha/patches/cloud-repo/0001-*.patch
    git push origin main

Each patch is `git format-patch` output, so `git am` preserves the
message and authorship. Verify it applies before pushing:

    git apply --check 0001-*.patch

## Contents

- `0001-c3-infra-mcp-gha-trigger-inputs-repo-rerun-run-logs.patch`
  Adds `inputs` / `ref` / `repo` to `devops.workflows.gha_trigger`, plus
  `devops.workflows.gha_rerun` and `devops.workflows.gha_run_logs`.
  Typechecked against the real dependency tree: 9 pre-existing errors
  before, 9 after, none in the added code.
