## FORBIDDEN PATTERNS

| NEVER | ALWAYS |
|-------|--------|
| `ssh vm 'echo > .secrets'` | `src/secrets.yaml` + sops + `build.sh ship` |
| `nix-env -i pkg` | Add to flake + rebuild |
| `sed` on VM `/etc/` files | Edit nix source + deploy |
| `docker compose up` on VM | `build.sh compose` |
| `which cmd` | `command -v cmd` |
| Edit `dist/` files | Edit `src/` + `build.sh build` |
| Edit `~/.claude/CLAUDE.md` | Edit source in `~/git/unix/` flakes |
| `cd dir && git mv dir/...` | `git -C /abs/path mv ...` (absolute paths) |
| `git add -f` / `git add --force` | plain `git add` — NEVER bypass gitignore. `-f` force-stages secrets, decrypted keys, sensitive/ — gitignore exists for a reason. |
