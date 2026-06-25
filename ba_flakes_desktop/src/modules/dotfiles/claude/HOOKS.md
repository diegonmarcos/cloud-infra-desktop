# Claude Code Hooks — generated reference

> **GENERATED from `hooks-rules.json` by `gen-hooks-doc.sh` — do not hand-edit.**
> Edit the registry, then `build.sh switch` (a drift test asserts this file is current).

Two axes classify every rule:
- **Reinforcement level** — `allow` (tier-0 short-circuit) · `deny` (block, exit 2) ·
  `warn` (advisory, exit 0) · `nudge` (PostToolUse soft) · `inject` (context prose).
- **Purpose category** — `secrets` · `data-loss` · `declarative-bypass` · `vm-imperative` ·
  `shell-safety` · `arch-guessing` · `context`.

Enforcement is **PreToolUse:Bash only**; SessionStart/UserPromptSubmit are injection-only;
the nudge is PostToolUse. The guard is **fail-closed** (unreadable registry ⇒ deny).

## Fires-on summary

| level | count | event |
|---|---|---|
| allow | 7 | PreToolUse:Bash |
| deny | 8 | PreToolUse:Bash |
| warn | 34 | PreToolUse:Bash |
| nudge | 1 | PostToolUse |
| inject | 6 | SessionStart,UserPromptSubmit, SessionStart,UserPromptSubmit,PreToolUse:Bash, UserPromptSubmit |

## ALLOW — tier-0 short-circuit (read-only, silent)

| id | category | event | pattern | reason | alt |
|---|---|---|---|---|---|
| `allow-npm-readonly` | context | PreToolUse:Bash | `^npm\s+(root|config|prefix|ls|list|ll|la|view|info|show|search|help|explain|doctor|audit|outdated|fund|pack|ping|whoami|token|profile|access|bugs|repo|completion|explore|-v|--version|-h|--help)(\s|$)` | read-only npm introspection — always allowed | — |
| `allow-nix-readonly` | context | PreToolUse:Bash | `^nix\s+(eval|show-derivation|path-info|log|why-depends|store|hash|doctor|registry|--version|--help|-h)(\s|$)` | read-only nix introspection — always allowed | — |
| `allow-nix-flake-readonly` | context | PreToolUse:Bash | `^nix\s+flake\s+(show|check|info|metadata)(\s|$)` | read-only nix flake introspection — always allowed | — |
| `allow-nix-profile-list` | context | PreToolUse:Bash | `^nix\s+profile\s+list(\s|$)` | read-only nix profile list — always allowed | — |
| `allow-docker-readonly` | context | PreToolUse:Bash | `^docker\s+(ps|images|logs|inspect|top|stats|diff|port|version|info|events|history|search|-v|--version|-h|--help)(\s|$)` | read-only docker introspection — always allowed | — |
| `allow-docker-net-vol-readonly` | context | PreToolUse:Bash | `^docker\s+(network|volume)\s+(ls|inspect)(\s|$)` | read-only docker network/volume introspection — always allowed | — |
| `allow-pip-readonly` | context | PreToolUse:Bash | `^pip3?\s+(list|show|freeze|check|config|--version|-V|--help|-h)(\s|$)` | read-only pip introspection — always allowed | — |

## DENY — hard block (exit 2)

| id | category | event | pattern / handler | reason | alt |
|---|---|---|---|---|---|
| `git-add-force` | secrets | PreToolUse:Bash | `(^|[;&|])\s*git\s+(-[Cc]\s+\S+\s+)?add\b[^;&|]*\s(-[A-Za-z]*f\b|--force\b)` | git add -f/--force bypasses gitignore — can stage decrypted secrets, private keys, sensitive/ | plain 'git add <path>'; if gitignore blocks a file, FIX gitignore — never force |
| `docker-compose-down-volumes` | data-loss | PreToolUse:Bash | `docker(-compose|\s+compose)\b[^;&|]*\sdown\b[^;&|]*\s(-v\b|--volumes\b)` | docker compose down -v wipes ALL named volumes (databases, state) — irreversible | docker compose down (without -v) or build.sh compose |
| `docker-volume-rm-prune` | data-loss | PreToolUse:Bash | `docker\s+volume\s+(rm|prune)\b` | docker volume rm/prune permanently deletes named volumes — irreversible | manual cleanup only after explicit user confirmation; inspect with 'docker volume ls' first |
| `docker-system-prune-volumes` | data-loss | PreToolUse:Bash | `docker\s+system\s+prune\s+.*--volumes\b` | docker system prune --volumes wipes everything including databases | targeted cleanup; inspect with 'docker system df' first |
| `nix-env-install` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*nix-env\s+(-i|--install|-iA)\b` | nix-env -i is imperative package management — pollutes the user profile and breaks declarative reproducibility | add the package to flake.nix (home.packages or environment.systemPackages) + build.sh switch |
| `secret-write-redirect` | secrets | PreToolUse:Bash | `(^|[;&|])\s*(echo|printf)\b[^|;]*>>?\s*[^|;]*((^|/)\.env([[:space:];|&]|$)|(^|/)\.secrets([[:space:];|&]|$)|secrets\.ya?ml([[:space:];|&]|$))` | imperative write (echo/printf >) to .secrets/.env/secrets.yaml bypasses sops | edit src/secrets.yaml + build.sh secrets |
| `secret-tee` | secrets | PreToolUse:Bash | `(^|[;&|])\s*tee\b[^|;]*\s+[^|;]*((^|/)\.env([[:space:];|&]|$)|(^|/)\.secrets([[:space:];|&]|$)|secrets\.ya?ml([[:space:];|&]|$))` | tee writing to .secrets/.env/secrets.yaml bypasses sops | edit src/secrets.yaml + build.sh secrets |
| `git-add-secret` | secrets | PreToolUse:Bash | `(^|[;&|])\s*git\s+(-[Cc]\s+\S+\s+)?add\b[^;|&]*(\.(env|key|pem|age|p12|pfx)([[:space:];|&]|$)|(^|/)\.secrets([[:space:];|&]|$)|secrets\.ya?ml([[:space:];|&]|$))` | git add of secret-shaped path — public-repo exposure risk | sops-encrypt secrets.yaml first; raw key material lives only in ~/git/vault |

## WARN — advisory (exit 0, first match wins)

| id | category | event | pattern | reason | alt |
|---|---|---|---|---|---|
| `warn-rsync-delete` | data-loss | PreToolUse:Bash | `rsync\s+.*--delete` | rsync --delete removes remote files not in source | build.sh deploy |
| `warn-npm-install` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*npm\s+install(\s|$)` | npm install bypasses declarative build system | build.sh deps (or build.sh build) |
| `warn-npm-ci` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*npm\s+ci(\s|$)` | npm ci bypasses declarative build system | build.sh deps |
| `warn-npm-run` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*npm\s+run(\s|$)` | npm run bypasses declarative build system | build.sh build (or build.sh dev) |
| `warn-npm-start` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*npm\s+start(\s|$)` | npm start bypasses declarative build system | build.sh dev |
| `warn-npm-test` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*npm\s+test(\s|$)` | npm test bypasses declarative build system | build.sh test |
| `warn-npx` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*npx\s` | npx bypasses declarative build system | build.sh build (esbuild/tsc/etc are run by the engine) |
| `warn-yarn` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*yarn(\s|$)` | yarn bypasses declarative build system | build.sh deps/build |
| `warn-pnpm` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*pnpm(\s|$)` | pnpm bypasses declarative build system | build.sh deps/build |
| `warn-nix-build` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*nix\s+build(\s|$)` | raw nix build bypasses the engine | build.sh build |
| `warn-nix-run` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*nix\s+run(\s|$)` | raw nix run bypasses the engine | build.sh build |
| `warn-nixos-rebuild` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*nixos-rebuild(\s|$)` | raw nixos-rebuild bypasses the engine | build.sh switch |
| `warn-home-manager` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*home-manager\s+(switch|build)(\s|$)` | raw home-manager switch/build bypasses the engine | build.sh switch |
| `warn-apt-install` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*apt(-get)?\s+install(\s|$)` | apt install is imperative — Nix flake declarative only | add to flake.nix |
| `warn-brew-install` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*brew\s+install(\s|$)` | brew install is imperative | add to flake.nix |
| `warn-pip-install` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*pip3?\s+install(\s|$)` | pip install is imperative | add to flake.nix or use nix-shell |
| `warn-conda-install` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*conda\s+install(\s|$)` | conda install is imperative | add to flake.nix |
| `warn-docker-compose-up` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*docker\s+compose\s+up(\s|$)` | docker compose up bypasses declarative deploy | build.sh compose (or build.sh ship) |
| `warn-docker-compose-up-legacy` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*docker-compose\s+up(\s|$)` | docker-compose up bypasses declarative deploy | build.sh compose |
| `warn-docker-compose-down` | declarative-bypass | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*docker\s+compose\s+down(\s|$)` | docker compose down bypasses declarative deploy | build.sh compose |
| `warn-docker-exec` | vm-imperative | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*docker\s+exec(\s|$)` | docker exec is imperative — never modify running containers | docker logs for read-only inspection |
| `warn-which` | shell-safety | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*which\s` | 'which' doesn't exist on Termux/Nix | command -v |
| `warn-cd-git-mv` | shell-safety | PreToolUse:Bash | `cd\s+[^[:space:];]+\s*&&\s*git\s+mv` | 'cd dir && git mv' kills the shell if CWD is moved | git -C /absolute/path mv ... |
| `warn-cd-rm-rf` | shell-safety | PreToolUse:Bash | `cd\s+[^[:space:];]+\s*&&\s*rm\s+-rf` | 'cd dir && rm -rf' kills the shell if CWD is deleted | rm -rf /absolute/path (use absolute paths) |
| `warn-ssh-write-redirect` | vm-imperative | PreToolUse:Bash | `ssh\s+\S+\s+.*\b(echo|sed|tee|cat|printf)\s.*>>?` | SSH write-redirect on a VM is imperative — declarative stack expects edit-source + build.sh ship | edit source in git repo (src/) + build.sh ship |
| `warn-ssh-sysctl` | vm-imperative | PreToolUse:Bash | `ssh\s+\S+\s+.*\bsysctl\s+-w` | SSH sysctl -w is imperative | add to nix config + build.sh ship |
| `warn-ssh-docker-exec` | vm-imperative | PreToolUse:Bash | `ssh\s+\S+\s+.*\bdocker\s+exec` | docker exec on remote VMs is forbidden | docker logs via SSH for read-only inspection |
| `warn-sops-decrypt` | secrets | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*sops\s+(-d|--decrypt)\b` | manual sops decrypt bypasses the engine | build.sh secrets |
| `warn-sops-decrypt-inplace` | secrets | PreToolUse:Bash | `\bsops\s+(-d|--decrypt)\s+(\S+\s+)*-i\b|\bsops\s+-d\s+-i\b|\bsops\s+-i\s+-d\b` | sops -d -i leaves secrets.yaml plaintext on disk — easy accidental git add | decrypt to stdout (sops -d file | …) or use build.sh secrets |
| `warn-ssh-secret-redirect` | secrets | PreToolUse:Bash | `ssh\s+\S+.*\.(secrets|env)\b.*>` | SSH write-redirect into a VM secret file bypasses sops | src/secrets.yaml on host + build.sh ship |
| `warn-docker-e-literal` | secrets | PreToolUse:Bash | `docker\s+(run|exec)\s+.*-e\s+[A-Z_]+=[A-Za-z0-9+/=._-]{16,}` | docker -e with literal credential value — leaks via shell history + ps | --env-file dist/.secrets (or compose env_file:) |
| `warn-curl-auth-literal` | secrets | PreToolUse:Bash | `curl\s+.*-H\s+["'](Authorization|X-API-Key|X-Auth-Token):\s*(Bearer\s+)?[A-Za-z0-9+/=._-]{16,}` | curl with literal token in Authorization header — leaks via history + transcript | use $TOKEN sourced from dist/.secrets |
| `warn-export-literal` | secrets | PreToolUse:Bash | `(^|\s|;|&&)\s*export\s+[A-Z][A-Z0-9_]*=[A-Za-z0-9+/=._-]{20,}` | export with long literal value looks like a hardcoded credential | source dist/.secrets instead |
| `warn-cat-secret` | secrets | PreToolUse:Bash | `(^|\s|;|&&|\|)\s*(cat|less|bat|head|tail)\s+[^|;]*(\.secrets\b|/\.env\b|\.key\b|\.pem\b|\.age\b)` | printing secret file to terminal leaks credentials into transcript/cache | sops --extract for one key, or pipe into a process: source dist/.secrets |

## NUDGE — PostToolUse soft reminder

| id | category | event | pattern / handler | reason | alt |
|---|---|---|---|---|---|
| `graph-nudge` | arch-guessing | PostToolUse | `handler:graph_nudge` | consecutive file reads/searches with no cloud-cgc-mcp query — use octocode_graphrag/search before reasoning about architecture | octocode_graphrag / octocode_search / knowledge_* / c3_* |

## INJECT — context prose by tier

| id | category | fragment | tiers |
|---|---|---|---|
| `inject-core-principles` | context | `hooks-fragments/core-principles.md` | SessionStart, UserPromptSubmit, PreToolUse:Bash |
| `inject-fire-rules` | context | `hooks-fragments/fire-rules.md` | UserPromptSubmit |
| `inject-stack-philosophy` | context | `hooks-fragments/stack-philosophy.md` | UserPromptSubmit |
| `inject-pre-action-checklist` | context | `hooks-fragments/pre-action-checklist.md` | SessionStart, UserPromptSubmit |
| `inject-forbidden-patterns` | context | `hooks-fragments/forbidden-patterns.md` | SessionStart, UserPromptSubmit |
| `inject-dead-shell-recovery` | context | `hooks-fragments/dead-shell-recovery.md` | UserPromptSubmit |
