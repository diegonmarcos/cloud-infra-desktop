# Diego's Master Context for Claude Agents

```
  ─────────────────────
  ───────────████████──     NO DINOSAUR SYNTAX!
  ──────────███▄███████
  ──────────███████████     Use modern Compose v2, current APIs,
  ──────────███████████     latest Nix patterns. If you catch
  ──────────██████─────     yourself writing deprecated syntax,
  ──────────█████████──     STOP and look up the modern way.
  █───────███████──────
  ██────████████████───     deprecated = extinct
  ███──██████████──█───
  ███████████████──────
  ███████████████──────
  ─█████████████───────
  ──███████████────────
  ────████████─────────
  ─────███──██─────────
  ─────██────█─────────
  ─────█─────█─────────
  ─────██────██────────
  ─────────────────────
```

> **Owner**: Diego Nepomuceno Marcos
> **System**: NixOS (Surface Pro 8) primary · Rescue-OS-Debian (p6) · Kali Linux (p7) · Windows (webcam-only) · Shared-Lib (p5, Docker storage)
> **Git Root**: `/home/diego/git`
<!-- INJECT:generated_date -->
> **Updated**: (static template — cloud-data not available at build time)
<!-- /INJECT -->

---

## Table of Contents

### OVERVIEW
- [Repository Map — Philosophy · Stack · Ops](#repository-map--philosophy--stack--ops)

### STACK
- [A. UNIX (NixOS & System Configuration)](#section-a-unix-nixos--system-configuration)
- [B. CLOUD INFRASTRUCTURE](#section-b-cloud-infrastructure)
- [C. SECURITY & CREDENTIALS](#section-c-security--credentials)
- [D. FRONT-END DEVELOPMENT](#section-d-front-end-development)
- [E. OPS & BUILD SYSTEM](#section-e-ops--build-system)
- [F. OTHERS (Quick Reference)](#section-f-others-quick-reference)

### SKILLS & MCPs
- [Skills](#skills)
- [MCP: cloud-infra](#mcp-cloud-infra)
- [APIs](#apis)

---

# ████████████████████████████████████████████████████████████████████████████
#               REPOSITORY MAP — Philosophy · Stack · Ops
# ████████████████████████████████████████████████████████████████████████████

Five git repos under `~/git/`. Same engine interface (`build.sh` + `build.json`) — different role.

| Repo | Visibility | Role |
|------|------------|------|
| `cloud` | **public** | Service infra — Nix flakes → Docker Compose, 60+ services on 5 VMs |
| `unix`  | **public** | NixOS host + home-manager (desktop, termux, builders, per-VM) |
| `front` | **public** | 32-project front-end monorepo → GitHub Pages |
| `vault` | **PRIVATE** | All credentials — sops + age + OAuth + SSH/WG/TOTP |
| `tools` | public | Cross-repo tooling (consumed as submodule from cloud / unix / front) |

---

## CLOUD (`~/git/cloud`) — public

**Philosophy** · Every service is a Nix flake → generated Docker Compose. Sops for all secrets. `build.sh ship` is the only deploy. Zero manual VM mutation. All services delivered as GHCR images (no Docker Hub direct).

**Stack**
- `a_solutions/<prefix>_<name>/` — 60+ services. Prefixes: `aa-sui` app · `ab-mic` mic · `ac-fin` fin · `ad-agi` agi · `ba-clo` cloud · `bb-sec` sec · `bc-obs` tools · `ca-dat` data
- `b_infra/nixhm-sudo-<vm>/` — per-VM home-manager (data-driven `build.json`; **master for public-port ownership** — `cloud/config.json` retired)
- `1_workflows/src/scripts/` — universal engine (build / secrets / deploy / compose), CI runners, pre-commit defence, cloud-builder launcher
- `2_configs/src/engines/` — derive scripts emit `cloud-data-*.json` (topology / caddy / dns / home-manager) consumed by all flakes
- **External-consumers registry** — `external-consumers.json` + `deriveExternalConsumers` emits `build-{flakes_desktop,flakes_termux,builders,secrets}.json` from a single consolidated source (unix + cloud-data both consume)
- **Port-enforcement shared lib** — Nix lib auto-injects port env vars from each service's `build.json`; flakes never hardcode ports
- Edge: Cloudflare → Caddy (gcp-proxy) → WireGuard mesh → service VM. Auth: Authelia 2FA / OIDC bearer tokens

**Ops**
- `build.sh ship` = build + secrets + deploy + compose (full pipeline)
- `CLOUD_PROFILE=<name> build.sh profile-ship` — deployment profiles (any topology, *not* DR / fallback)
- GHA: `ship-{gcp-proxy,oci-apps,oci-mail,oci-analytics,home-manager}.yml` (path-triggered on `main`)
- Submodules (`cloud/tools`, `cloud/I_cloud-data`) are read-only from parent → edit source clone (`~/git/tools`, `~/git/I_cloud-data`)
- Builders: `cloud-builder-x` (multi-arch via QEMU on oci-apps), `forge` (52GB x86 cache)
- Backups: Dagu DAG → restic → OCI S3, daily 03:00; per-service strategy declared in `build.json`

---

## UNIX (`~/git/unix`) — public

**Philosophy** · Pure NixOS + home-manager flakes. Root is tmpfs (impermanence). HM modules consume cloud-data-derived JSON. **VMs receive HM as Docker images** (1GB hosts can't `nix eval` — they OOM).

**Stack**
- `aa_nixos-surface_host/` — Surface Pro 8 (LUKS + USB keyfile, KDE Plasma 6, linux-surface kernel, btrfs subvolumes)
- `aa_bootloader/` — rEFInd primary, GRUB secondary; multi-boot (Rescue / Kali / Windows / Ventoy)
- `ba_flakes_desktop/` — home-manager desktop *(this CLAUDE.md lives here under `src/modules/dotfiles/claude/`)*
- `bb_flakes_termux/` — home-manager termux (nix-on-droid)
- Container images shipped from this repo: `cloud-builder-x` (multi-arch builder), `vm-pilot` (37 HM modules consolidated)

**Ops**
- `build.sh switch | boot | test | check | update | diff | install` — one engine, all flakes
- `build.sh build {raw|iso|qcow|vm}` — bootable artefacts; `build.sh burn` — flash USB
- VM home-manager delivery: GHCR image push → VMs `docker pull` + activate (no nix eval at runtime)
- System-protection: 3-tier cgroup slice hierarchy (FIFO scheduling on SSH / WG / Dropbear) on all VMs + desktop

---

## FRONT (`~/git/front`) — public

**Philosophy** · TypeScript strict everywhere. Svelte 5 runes / Vue 3 Composition API. **No inline CSS** (SCSS mixins only). **No `fetch()` for JSON** — use `data-<key>.json.js` wrappers exposing `globalThis.PORTAL_DATA[key]` (CORS-safe, works under `file://`). Matomo tracking required on every HTML head.

**Stack**
- `1.ops/` — `00_Stack_Main.md` spec, `30_Code_Practise.md`, `build_main.sh` master TUI
- `<category>/<project>/` — Sass + Vite + SvelteKit / Vue / vanilla TS, with per-project `build.sh` + `build.json`
- SCSS mixins: `@include mq(sm|md|lg|xl)`, `flex-center`, `flex-row(j,a,gap)`, `grid-auto-fit(min,gap)`
- Dev ports: 8000–8022 (assigned per project, no conflicts)

**Ops**
- `1.ops/build_main.sh` — interactive TUI for all 32 projects
- `<project>/build.sh build | dev | deploy` — single project
- Deploy target: `diegonmarcos.github.io` (GitHub Pages)
- After source edits: `build.sh build` (never `dev` / `serve` unless explicitly asked)

---

## VAULT (`~/git/vault`) — **PRIVATE**

**Philosophy** · The only place credentials live. Public repos reference vault *paths* only — never copy values. Sops-encrypted where possible; raw key material (age keys, SSH private keys) is itself the credential and lives here as canonical store.

**Stack**
- `A0_keys/`
  - `ssh/` — symlinked into `~/.ssh/`
  - `providers/{authelia,cloudflare,gcloud,github,nocodb,oci,system,wireguard}/` — provider-scoped
  - `api_tokens.json` — master credentials index
- `B0_Passwords/`, `B1_2fa/` (TOTP + recovery), `B2_Wifi/`
- `C0_ID/`, `C1_Payment/`, `C2_Notes/`
- `D0_bitwarden/` — exported vault

**Ops**
- Bearer tokens (interactive 2FA): `python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py`
- Pre-signed JWTs (CI/automation): `~/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/`
- Local MCP `diego-personal-data` — 16 read-only tools (`vault_*`, `identity_*`, `finance_*`, `media_*`)
- **Carve-out from Pillar 7B**: vault is the *only* repo where raw key material may be `git add`ed (private + sops-at-rest)

---

# ████████████████████████████████████████████████████████████████████████████
#                                 STACK
# ████████████████████████████████████████████████████████████████████████████

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION A: UNIX (NixOS & System Configuration)
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/unix/README.md`

## A.1 System Overview

| Component | Details |
|-----------|---------|
| **Primary OS** | NixOS 24.11 (Surface Pro 8) |
| **Bootloader** | rEFInd (UEFI), owned by `aa_bootloader/` engine |
| **Multi-boot** | Rescue-OS-Debian (p6, ext4) · Kali Linux (p7, ext4) · Windows (ESP chainload, webcam-only) · Ventoy USB (LUKS keyfile + multi-OS live) |
| **Data partition** | Shared-Lib (p5, ext4 → `/mnt/shared-lib`, Docker data-root) |
| **Kernel** | linux-surface (mainline 6.15+ with Surface patches) |
| **Desktop** | KDE Plasma 6 (Wayland), GNOME, Openbox available |
| **Shell** | Fish (default), Zsh, Bash available |

## A.2 Key Paths & Build

> Paths in **Repo Map → UNIX**. Engine commands: `~/git/unix/<flake>/build.sh -h` (cmds: `switch | boot | test | check | update | diff | install | build {raw|iso|qcow|vm} | burn`).

**Host Configs**: `surface-plasma` (all 8 profiles + Plasma 6), `surface-gnome`, `server`, `cli`, `minimal`.

## A.3 Agent-Essential Notes

- **Impermanence**: Root is tmpfs — `/nix` and `/home/*` are persistent btrfs subvolumes
- **LUKS**: Full disk encryption, USB keyfile with password fallback
- **initrd**: Surface keyboard needs `surface_aggregator`, `surface_hid` loaded early
- **No Intel ISH**: Surface Pro 8 uses SAM, not Intel Integrated Sensor Hub
- **Docker/Podman**: Data stored at `/mnt/shared-lib/docker` (p5, former Kubuntu partition repurposed 2026-05-04)
- **Bootloader**: NixOS yields all bootloader management to `aa_bootloader/` (rEFInd primary, GRUB secondary). Run `aa_bootloader/build.sh deploy` after any flake change that affects boot.

## A.4 Terminal Welcome (rendered fish greeting)

```
<!-- INJECT:fish_greeting -->
(fish greeting not available at build time)
<!-- /INJECT -->
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION B: CLOUD INFRASTRUCTURE
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/cloud/README.md`. Paths / role overview in **Repo Map → CLOUD**.

## B.1 Virtual Machines

<!-- INJECT:vm_table -->
| VM | Alias | IP | WG IP | Description |
|----|-------|-----|-------|-------------|
| (cloud-data not available at build time — use `c3_topology` MCP tool) | | | | |
<!-- /INJECT -->

## B.2 Networking

Traffic flow: **Cloudflare -> Caddy (gcp-proxy) -> WireGuard -> target VM**. Auth: Authelia 2FA (browser) or Bearer token via introspect-proxy (CLI/API).

<!-- INJECT:ssh_aliases -->
SSH aliases: (generated from cloud-data at activation time).
<!-- /INJECT -->

## B.3 Active Services

<!-- INJECT:services_table -->
| Service | Domain | VM | Category |
|---------|--------|-----|----------|
| (cloud-data not available at build time — use `c3_configs` MCP tool) | | | |
<!-- /INJECT -->

## B.4 Bearer Token Auth (CLI Access)

```bash
# Get token (interactive, opens browser for 2FA)
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py

# Use token
TOKEN=$(jq -r .access_token ~/git/vault/A0_keys/providers/authelia/oauth/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://<service>.diegonmarcos.com/...
```

> Matomo hybrid toggle, IP change management, security stack details: See `~/git/cloud/README.md`

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION C: SECURITY & CREDENTIALS
# ══════════════════════════════════════════════════════════════════════════════

## C.1 Vault Repository

| Resource | Path |
|----------|------|
| **Vault Repo** | `/home/diego/git/vault` |

**WARNING**: Contains sensitive credentials. NEVER expose or commit to public repos.

## C.2 Vault Structure

```
/home/diego/git/vault/
├── A0_keys/
│   ├── ssh/                  # SSH keys (symlinked to ~/.ssh/)
│   ├── providers/
│   │   ├── authelia/oauth/   # Bearer token + get_token.py
│   │   ├── cloudflare/       # DNS API credentials
│   │   ├── gcloud/           # Google Cloud CLI config
│   │   ├── github/           # GitHub CLI + OAuth tokens
│   │   ├── nocodb/           # NocoDB API tokens
│   │   ├── oci/              # Oracle Cloud CLI config
│   │   ├── system/           # System-level credentials
│   │   └── wireguard/        # VPN keys
│   └── api_tokens.json       # Master credentials file
├── B0_Passwords/             # Service passwords
├── B1_2fa/                   # TOTP seeds + recovery codes
├── B2_Wifi/                  # WiFi connection configs
├── C0_ID/                    # Identity documents
├── C1_Payment/               # Payment card info
├── C2_Notes/                 # Secure notes
└── D0_bitwarden/             # Bitwarden vault export
```

## C.3 Security Stack

| Layer | Components |
|-------|------------|
| **Network Edge** | Cloudflare Proxy, Cloud Firewalls |
| **Traffic** | Caddy Reverse Proxy, Let's Encrypt TLS |
| **Authentication** | Authelia 2FA (TOTP/WebAuthn), OIDC bearer tokens |
| **Token Validation** | introspect-proxy (OIDC introspection sidecar) |
| **Application** | Docker Networks, WireGuard VPN, Container Isolation |
| **Credentials** | Vaultwarden (passwords), Aegis (TOTP) |

## C.4 CLI Authentication

```bash
# GitHub CLI
gh auth status

# Oracle Cloud CLI
oci session authenticate

# Google Cloud CLI
gcloud auth login

# Authelia bearer token (for Caddy-protected services)
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION D: FRONT-END DEVELOPMENT
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/front/README.md` and `~/git/front/1.ops/` for specs

## D.1 Repository & Resources

| Resource | Path |
|----------|------|
| **Front Repo** | `/home/diego/git/front` |
| **Stack Spec** | `/home/diego/git/front/1.ops/00_Stack_Main.md` |
| **Code Practices** | `/home/diego/git/front/1.ops/30_Code_Practise.md` |
| **Master Build** | `/home/diego/git/front/1.ops/build_main.sh` |

## D.2 Build System

```bash
~/git/front/1.ops/build_main.sh           # Interactive TUI (all projects)
~/git/front/1.ops/build_main.sh build     # Build all
~/git/front/<category>/<project>/build.sh build    # Single project
~/git/front/<category>/<project>/build.sh dev      # Dev server
```

## D.3 Code Standards

### TypeScript
- **Strict Mode**: No `any`, handle `null`/`undefined`
- **DOM**: Cast elements explicitly, check null
- **ES Modules**: Use `import`/`export`

### Svelte 5 (Runes Mode) - CRITICAL
```typescript
let { propName }: { propName: Type } = $props();  // Props
let count = $state(0);                             // State
let doubled = $derived(count * 2);                 // Computed
// Events: use standard HTML (onclick, not on:click)
```

### Vue 3 (Composition API)
```typescript
// Always use <script setup lang="ts">
defineProps<{ id: number; name: string }>();
const user = ref<User | null>(null);
```

### SCSS Rules
```scss
@include mq(sm|md|lg|xl)           // Breakpoints
@include flex-center;               // Center anything
@include flex-row(justify, align, gap);
@include grid-auto-fit(min-size, gap);
```

### CRITICAL: NO INLINE CSS
- **NEVER** use `style=""` attributes in HTML
- **ALWAYS** create SCSS classes in appropriate `_*.scss` file
- ALL styling must go through the SCSS build pipeline

### HTML Standards
- **Semantic**: Use `<header>`, `<nav>`, `<main>`, `<section>`, `<article>`, `<footer>`
- **Links vs Buttons**: `<a>` for navigation, `<button>` for actions
- **Accessibility**: All `<img>` have `alt`, inputs have `<label>`

## D.4 Analytics (Matomo)

**Required in every HTML `<head>`:**
```html
<script>
var _mtm = window._mtm = window._mtm || [];
_mtm.push({'mtm.startTime': (new Date().getTime()), 'event': 'mtm.Start'});
(function() {
  var d=document, g=d.createElement('script'), s=d.getElementsByTagName('script')[0];
  g.async=true; g.src='https://analytics.diegonmarcos.com/js/container_odwLIyPV.js';
  s.parentNode.insertBefore(g,s);
})();
</script>
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION E: OPS & BUILD SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

## ⚠️ CRITICAL: NIX WAY — ALWAYS FLAKES IN THE REPO ⚠️

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   NEVER use system-level flakes. Flakes live IN the repository.  ║
║                                                                  ║
║   Every project uses build.sh (engine) + build.json (config)     ║
║   at project root.                                               ║
║                                                                  ║
║   build.sh is the ONLY build interface. ALWAYS use it.           ║
║                                                                  ║
║   NEVER run nix build/switch/etc. directly — use the repo's      ║
║   build.sh.                                                      ║
║                                                                  ║
║   NEVER edit deployed/output files directly (e.g. ~/.claude/,    ║
║   dist/, ~/). ALWAYS find and edit the SOURCE in the git repo    ║
║   flake. This file (CLAUDE.md) is deployed output — its source:  ║
║     ~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/    ║
║     ~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/     ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

### GitHub Actions CI/CD (cloud/ repo)

**Cloud repo has GHA workflows** in `.github/workflows/` that auto-deploy on push to `main`:

| Workflow | Trigger (path) | What it does |
|----------|---------------|-------------|
| `ship-gcp-proxy.yml` | `bb-sec_caddy/`, `bb-sec_authelia/`, etc. | Ship services to gcp-proxy |
| `ship-oci-apps.yml` | `bc-obs_c3-infra-mcp-api/`, `bb-sec_rust-api/`, `bc-obs_rig/`, etc. | Ship services to oci-apps (REMOTE_BUILD for Docker) |
| `ship-oci-apps-1.yml` | `aa-sui_*` services | Ship services to oci-apps-1 |
| `ship-oci-mail.yml` | `aa-sui_tools-mailu/`, etc. | Ship services to oci-mail |
| `ship-oci-analytics.yml` | `bc-obs_*` services | Ship services to oci-analytics |
| `ship-home-manager.yml` | `b_infra/**` | Deploy home-manager to all VMs (cascaded by ship-gen-configs) |

All workflows use: `cachix/install-nix-action`, SSH key from secrets, SOPS age key, then `build.sh ship`.
Services with Docker images use `REMOTE_BUILD=true` (builds on target VM, avoids cross-compilation).
All workflows support `workflow_dispatch` for manual triggering with optional service filter.

**IMPORTANT**: Pushing to `main` with changes in `a_solutions/*/src/` triggers auto-deploy. Be aware of this when committing.

### ⚠️ Cloud Service Structure (MANDATORY)

```
⚠️ BEFORE modifying ANY cloud/ service: READ ~/git/cloud/README.md
   THIS IS NOT OPTIONAL — it is the full spec for the cloud build system.
```

Every service in `` MUST follow this exact structure:

```
<category-prefix>_<name>/
├── build.sh        <- Universal engine (DO NOT customize — copy from template)
├── build.json      <- Service config (name, description, deploy target)
└── src/
    ├── flake.nix   <- REQUIRED — Nix flake that builds config files -> dist/
    ├── secrets.yaml <- Optional, sops-encrypted (age key)
    └── ...          <- Service-specific source files
```

**build.json schema** (cloud/ services) — common fields:
```json
{
  "name": "service-name",
  "description": "What this service does",
  "deploy": {
    "host": "ssh-alias (gcp-proxy / oci-apps / oci-mail / oci-analytics) or 'local'",
    "remote_path": "/opt/containers/<service-name>"
  },
  "ports":   { /* port → owned_by + source mappings (Pillar 7-adjacent) */ },
  "secrets": { "escape_dollars": true /* required for Argon2 / PBKDF2 hashes */ },
  "backup":  { /* per-service strategy consumed by Dagu DAG */ },
  "image":   { /* GHCR image config when service is delivered as Docker image */ }
}
```
> Authoritative: `~/git/cloud/README.md` + the live `build.json` of any reference service. Not all fields are required for every service.

**build.sh pipeline steps** (same for ALL services — NEVER create custom steps):

| Command | What it does |
|---------|-------------|
| `build` | `nix build` in `src/` -> copy result to `dist/` + any extra build steps |
| `secrets` | `sops -d src/secrets.yaml` -> `dist/.secrets` (KEY=VALUE env file) |
| `deploy` | `rsync dist/` -> VM via SSH (or local copy for local services) |
| `compose` | `docker compose up -d` on VM (or equivalent for local services) |
| `all` | `build + secrets` (default) |
| `ship` | `build + secrets + deploy + compose` (FULL PIPELINE — use this to deploy) |
| `clean` | Remove `dist/` and `.result` |

**Template reference**: `bb-sec_authelia/build.sh` — copy this for new services.

**Category prefixes**: `aa-sui_` (app), `ab-mic_` (mic), `ac-fin_` (fin), `ad-agi_` (agi), `ba-clo_` (cloud), `bb-sec_` (sec), `bc-obs_` (tools), `ca-dat_` (data)

## E.1 Working Directory Rule

**ALL Claude Code sessions MUST start from `~/.claude` directory.**
This ensures consistent context loading and access to CLAUDE.md instructions.

## E.1.2 Guard-Rails (hooks)

> Source: `~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/`. Wired via `settings.json`. Deployed by home-manager to `~/.claude/hooks/`.

### Hook lifecycle

| Tier | Event | Script | Role |
|------|-------|--------|------|
| **A** | SessionStart (1×/session) | `a-context-inject-memory.sh` | Inject full CORE PRINCIPLES + checklist + forbidden patterns into session context |
| **B** | UserPromptSubmit (every prompt) | `b-context-inject-prompt.sh` | Re-inject CORE + FIRE rules + Stack Philosophy + dead-shell recovery |
| **C₀** | PreToolUse:Bash (every Bash call) | `c-context-inject-pretool.sh` | Compact CORE reminder via `hookSpecificOutput.additionalContext` (JSON) |
| **C₁** | PreToolUse:Bash (every Bash call) | `c-pretool-guard-blockers.sh` | **Hard deny** — `exit 2`, tool call refused, stderr explains reason |
| **C₂** | PreToolUse:Bash (every Bash call) | `c-pretool-guard-warning.sh` | **Advisory** — `exit 0` + stderr note, command proceeds |

Commit-time defence: `1_workflows/src/hooks/pre-commit` blocks any gitignored file from being committed.

### Hard blockers (Tier C₁ — `exit 2`)

| # | Pattern | Reason |
|---|---------|--------|
| 1 | `git add -f` / `--force` | Bypasses gitignore — leaks secrets / decrypted keys / `sensitive/` |
| 2 | `docker compose down -v\|--volumes` | Wipes named volumes (DBs) — irreversible |
| 3 | `docker volume rm\|prune` | Irreversible per-volume deletion |
| 4 | `docker system prune --volumes` | Same blast radius as volume prune |
| 5 | `nix-env -i\|-iA\|--install` | Imperative profile pollution; breaks reproducibility |
| 6 | `(echo\|printf\|tee) ... >.*\.(secrets\|env)` | **Pillar 7A** — imperative plaintext write to secret file |
| 7 | `git add` of `.env` / `.key` / `.pem` / `.age` / `*secret*` | **Pillar 7B** — plaintext secret-shape stage. Carve-outs: inside `~/git/vault/`, or `secrets.yaml` containing sops marker (`^sops:` / `ENC[AES256_GCM`) |

### Always-allow (Tier 0 — skip all warnings)

Read-only introspection passes silently:
- **npm**: `root`, `config`, `prefix`, `ls`, `view`, `info`, `show`, `search`, `help`, `doctor`, `audit`, `outdated`, `fund`, `pack`, `ping`, `whoami`, `token`, `profile`, `access`, `bugs`, `repo`, `--version`, `--help`
- **nix**: `eval`, `show-derivation`, `path-info`, `log`, `why-depends`, `store`, `hash`, `doctor`, `registry`; `flake show/check/info/metadata`; `profile list`
- **docker**: `ps`, `images`, `logs`, `inspect`, `top`, `stats`, `diff`, `port`, `version`, `info`, `events`, `history`, `search`; `network/volume ls/inspect`
- **pip**: `list`, `show`, `freeze`, `check`, `config`, `--version`, `--help`

### Warnings (Tier C₂ — advisory, command still runs)

**Build-pipeline bypass** → use `build.sh`
- `npm install` / `ci` / `run` / `start` / `test`, `npx`, `yarn`, `pnpm`
- raw `nix build` / `nix run`, `nixos-rebuild`, `home-manager switch` / `build`
- `apt install`, `brew install`, `pip install`, `conda install`
- `docker compose up` / `down`, `docker exec`
- `rsync --delete`

**Shell antipatterns**
- `which` → use `command -v`
- `cd <dir> && git mv <dir>/...` → use `git -C /abs/path mv …`
- `cd <dir> && rm -rf` → use absolute paths (kills shell if CWD removed)

**SSH imperatives** — never mutate VMs by hand
- `ssh vm '... echo/sed/tee/cat/printf ... >>?'` (write-redirect)
- `ssh vm '... sysctl -w'`
- `ssh vm '... docker exec'`
- `ssh vm '... > .secrets|.env'` (remote secret-file write — **Pillar 7A**)

**Secrets (Pillar 7)** — complements blockers #6 / #7
- `sops -d` / `--decrypt` (manual decrypt outside the engine)
- `sops -d -i` (in-place decrypt — leaves plaintext on disk, primes accidental `git add`)
- `docker run/exec -e KEY=<long literal>` (inline credential leaks via `ps` + history)
- `curl -H "Authorization: Bearer <literal>"` (literal token in transcript)
- `export FOO=<long literal>` (hardcoded credential in env)
- `cat` / `less` / `bat` / `head` / `tail` of `.secrets` / `.env` / `.key` / `.pem` / `.age`

### Quick-reference forbidden patterns

| NEVER | ALWAYS |
|-------|--------|
| `ssh vm 'echo > .secrets'` | `src/secrets.yaml` + sops + `build.sh ship` |
| `nix-env -i pkg` | Add to flake + rebuild |
| `sed` on VM `/etc/` files | Edit nix source + deploy |
| `docker compose up` on VM | `build.sh compose` |
| `which cmd` | `command -v cmd` |
| Edit `dist/` files | Edit `src/` + `build.sh build` |
| Edit `~/.claude/CLAUDE.md` | Edit source in `~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/.../CLAUDE.md.tpl` |
| `cd dir && git mv dir/...` | `git -C /abs/path mv ...` (absolute paths) |
| **`git add -f` / `git add --force`** | **plain `git add` — NEVER bypass gitignore.** |
| **Hardcoded secret in source** | **`src/secrets.yaml` + sops + `build.sh secrets` (Pillar 7A)** |
| **`git add` of `.env` / `.key` / `.pem` / `.age` / `*secret*` / plaintext `secrets.yaml`** | **Encrypt first; raw key material lives only in `~/git/vault` (Pillar 7B)** |

## E.2 Dependency Verification (CRITICAL)

**ALWAYS check and install ALL dependencies before declaring a feature complete.**

1. **Research dependencies FIRST** - Check official docs, package info
2. **Check runtime dependencies** - Not just build deps
3. **Test ALL features** - Don't just check "it launches"
4. **Verify helper scripts work** - TEST THEM
5. **Document dependencies** - Add comments explaining WHY

```bash
# Check package dependencies
pacman -Qi <package>        # Arch/NixOS
apt depends <package>       # Debian
rpm -qR <package>           # RPM-based
```

**NEVER remove a feature because dependencies are missing - FIX THE DEPENDENCIES.**

## E.3 Operational Gotchas

> Hard-won lessons. Surfaced from auto-memory so each new session inherits them — don't re-discover.

### Secrets pipeline
- **`escape_dollars: true`** in `build.json` for any service whose `.secrets` values contain `$` (Argon2 / PBKDF2 hashes, user passwords). Without it, docker-compose `env_file` interprets `$` as variable refs and silently mangles values. Engine doubles `$` → `$$`; compose unwraps back.
- **Use `awk`, never `sed`**, when substituting secret values that contain `$`. `sed` interprets `$` in replacement strings as backreferences and silently corrupts hashes. Pattern: `awk -v pat="..." -v rep="$val" '{ ...index()... }'`.
- **Authelia 4.38+ OIDC `client_secret`** must be a proper password digest (`$pbkdf2-sha512$…`), not a plain hex hash. NEVER pin `authelia:latest` — pin `4.39.x` or specific.
- **PBKDF2 (Authelia)**: `docker run --rm authelia/authelia:4.39.15 authelia crypto hash generate pbkdf2 --password 'SECRET'`.
- **Argon2 (Vaultwarden)**: `vaultwarden hash` requires a real TTY. Workaround: `nix-shell -p libargon2 openssl --run 'echo -n "PASS" | argon2 "$(openssl rand -base64 16)" -id -m 16 -t 3 -p 4 -l 32 -e'`.
- **SOPS key precedence**: container entrypoints must prefer mounted RO `keys.txt` over an env-var write — otherwise CI jobs fail with "Read-only file system".

### Docker / VMs
- **Never run manual `docker compose` on E2 Micro VMs** (1GB) — concurrent compose ops freeze the kernel. Use `build.sh ship` (sequential).
- **Never run `nix eval` / `home-manager switch` on 1GB VMs** — they OOM. HM uses Docker image delivery (GHCR push → VM pulls + activates).
- **Slow VMs are collect-only** — no `docker cp`, YARA, `exec`, `tar`, or agents at scan time. Treat as read-only data stores.
- **Caddy fallback uses raw WireGuard IPs** (cloud-data uses `.app` names with wildcard → self; the fallback file is plain IPs). Don't "fix" the apparent inconsistency — it's intentional.
- **Caddy wormhole returns HTTP 200** on missing routes (global fallback HTML). Always inspect the response *body*, not status code, on `*.diegonmarcos.com` health checks.

### Shell / git
- **CWD deleted by `git mv` / `rm -rf`** kills the shell — Bash silently exits 1 on every command. Recovery: `Write` tool or `mkdir -p <deleted-path>` to restore CWD as a string reference. Then use absolute paths.
- **`echo "$VAR" | while read`** runs the loop in a subshell — variables don't propagate. Use `mapfile` + `for` instead.
- **`local`** only works inside functions, not loop bodies.
- **Submodules are read-only from parent** — never stage / commit submodule pins or edits from the parent repo. If dirty: `cd submodule && git nuke` (fetch + reset --hard origin + clean -fdx).
- **Always edit the source clone**, not the submodule path: edit `~/git/tools/` (not `~/git/cloud/tools/`); edit `~/git/I_cloud-data/` (not `~/git/cloud/I_cloud-data/`).
- **`cp` is interactive on this system** (alias). Use `command cp -f` to bypass.

### NixOS / home-manager / Plasma
- **plasma-manager `configFile` escapes `]` `[`** in section names → broken `\x5d\x5b` headers. Use `kwriteconfig6` in `home.activation` for hierarchical KDE INI groups.
- **PHP-FPM multiple instances**: each needs its own main config with `[global]` + separate `pid`. Pool files in `pool.d/` are for a single FPM loading multiple pools.
- **Two host-network php-fpm services collide on :9000**. Use unix socket via `zzz-*.conf` override.
- **Debian Bookworm**: PHP 8.2 native (`php8.2-fpm`); `php8.2-maxminddb` not in repos — install via PECL.

### Workflows / data-driven
- **Dagu `command: >-` (folded scalar)** is exec'd directly without a shell — `$VAR` becomes a literal `${VAR}`. Always use `command: |` for shell expansion.
- **No `fetch('foo.json')` in front projects** — read `globalThis.PORTAL_DATA[key]` from `data-<key>.json.js`. CORS-safe + works under `file://`.
- **Search ALL sections** when querying JSON data — never cherry-pick keys.

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION F: OTHERS (Quick Reference)
# ══════════════════════════════════════════════════════════════════════════════

## F.1 Repo directory trees (auto-generated, dirs only, depth 4)

<!-- INJECT:repo_trees -->
(repo trees not available at build time — generated by gen-claude-md.sh from `tree -d -L 4` on each repo)
<!-- /INJECT -->

## F.2 Domains

- **Main**: diegonmarcos.com (Cloudflare DNS)
- **GitHub Pages**: diegonmarcos.github.io

## F.3 Behavioral rules for Claude

> Conventions reinforced across sessions. Code-derivable rules live in the relevant section; this list captures meta-rules about *how to operate*.

1. **"Explain" / "how does it work" / "what is" are READ-ONLY.** Describe; do not edit, refactor, or "improve" while explaining. Opinions ≠ orders.
2. **No unnecessary deploys.** Never `ship` a service that isn't explicitly in scope — causes container conflicts and downtime.
3. **Profile ≠ fallback.** Deployment profiles (`CLOUD_PROFILE=<name> build.sh profile-ship`) are a generic topology system. Never frame as DR / fallback / "backup VM".
4. **Read specs first.** Before modifying any project, read its `README.md` / `1.ops/` spec / `build.json`.
5. **`cloud-data` is the source of truth** for cloud infrastructure (auto-injected into B.1 / B.3).
6. **Search ALL keys** when querying JSON data — never cherry-pick a section.
7. **After source edits → `build.sh build`** automatically. Never `dev` / `serve` unless the user explicitly asks.

---

# ████████████████████████████████████████████████████████████████████████████
#                           SKILLS & MCPs
# ████████████████████████████████████████████████████████████████████████████

> **READ vs EXEC split** — three MCPs, three roles:
> - **`code-graph-context`** (stdio) — *READ* layer: infra knowledge graph, semantic code search, docs
> - **`diego-personal-data`** (stdio) — *READ* layer (local): vault, identity, finance, media
> - **`cloud-infra`** (stdio + HTTP) — *EXEC* layer: Chef (SSH/Docker/build) + Waiter (C3 API health/control)
>
> Companion: `c3-services-api` (REST + OpenAPI consolidation) and `c3-services-mcp` (MCP tools) are dual-hub — `shared/` must be independent, not symlinked.

## MCP: code-graph-context (stdio, knowledge graph + infra)

**Source**: `~/git/cloud/a_solutions/bc-obs_code-graph-context-kg-infra-mcp/src/` · **23 tools, 2 resources**

### Section A: Raw JSON Infra Knowledge (17 tools)

#### Specs (9 tools)
| Tool | When to use |
|------|-------------|
| `c3_topology` | Full infrastructure map (VMs, services, networking) |
| `c3_configs` | Generated config (domains, ports, images, routes) |
| `c3_deps` | Cloud service npm dependencies |
| `c3_topology_md` | Human-readable topology |
| `c3_configs_md` | Human-readable configs (Caddy, Authelia, DNS) |
| `c3_deps_front` | Front-end project dependencies |
| `knowledge_service_spec` | Service build.json + flake.nix + topology |
| `knowledge_vm_info` | VM details — IP, WG IP, services, SSH alias |
| `knowledge_services_by_category` | All services grouped by category |

#### Docs (4 tools)
| Tool | When to use |
|------|-------------|
| `c3_docs_overview` | Cloud docs portal overview + index |
| `c3_docs_service` | Service-specific documentation |
| `c3_readme` | Cloud repo README.md |
| `cloud_context` | Dynamic infrastructure summary (compact/full) |

#### Skills (4 tools)
| Tool | When to use |
|------|-------------|
| `skill_cloud_architect` | Infrastructure tasks — deploy, networking, VM lifecycle |
| `skill_frontend_developer` | Front-end project work — build, dev, code standards |
| `skill_debug_ops` | Debug containers, logs, health issues |
| `skill_crawlee_scraping` | Web scraping, data extraction |

### Section B: Octocode — Semantic Code Search (3 tools)
| Tool | When to use |
|------|-------------|
| `octocode_search` | Semantic code search across indexed repositories |
| `octocode_graphrag` | Query code relationship graph — search nodes, get relationships, find paths, overview |
| `octocode_index` | Trigger re-indexing of a repository or directory |

### Section C: CodeGraph-Rust — Graph Analysis (3 stub tools, future)
| Tool | When to use |
|------|-------------|
| `codegraph_trace_call_path` | [Future] Trace full call chains between functions |
| `codegraph_impact_analysis` | [Future] Analyze blast radius of code changes |
| `codegraph_dependencies` | [Future] Query dependency graph for modules/files |

### Resources
| URI | Description |
|-----|-------------|
| `cloud://context/compact` | ~10k token infrastructure summary |
| `cloud://context/full` | ~50k token full infrastructure context |

## MCP: diego-personal-data (stdio, local vault/personal data)

**Source**: `~/git/cloud/a_solutions/ca-dat_c3-diego-personal-data-mcp/src/` · **16 tools, READ-ONLY**

| Category | Tools |
|----------|-------|
| Vault | `vault_structure`, `vault_providers`, `vault_ssh_keys`, `vault_passwords_summary`, `vault_2fa_status` |
| Identity | `identity_documents`, `identity_notes`, `identity_read_note` |
| Comms | `comms_email_status`, `comms_whatsapp` (TBD), `comms_notes` (TBD) |
| Media | `media_photos`, `media_git_repos` |
| Finance | `finance_cards`, `finance_wifi` |
| Health | `health_data` (TBD) |

## MCP: cloud-infra

**Repo**: `~/git/cloud/a_solutions/bc-obs_c3-infra-mcp-api/` | **SDK**: `@modelcontextprotocol/sdk ^1.12.0`

### Architecture — Hybrid "Chef + Waiter" Model

| Layer | Tools | What it does |
|-------|-------|-------------|
| **Chef (Native)** | `ssh_exec`, `check_vm`, `docker_ps`, `docker_control`, `docker_logs`, `docker_compose_up` | Direct SSH/Docker — works even if C3 API is down |
| **Chef (Build)** | `build_service`, `build_all`, `build_ship`, `build_docker`, `secrets_status`, `backup_trigger` | Nix build pipeline, deployment, secrets, backups |
| **Chef (Repo)** | `read_file`, `search_repos`, `list_directory`, `reload_config` | Read files across all 5 repos (cloud, unix, vault, front, tools) |
| **Waiter (Read)** | `health_alive`, `health_declared`, `health_deployed`, `health_drift`, `health_status`, `profile_container`, `profile_vm`, `service_list_apis`, `service_get_info`, `service_get_spec`, `service_discover_all` | C3 API — health, profiling, API discovery |
| **Waiter (Write)** | `vm_start`, `vm_stop`, `vm_reset`, `container_start`, `container_stop`, `container_restart`, `service_start`, `service_stop`, `service_api_call` | C3 API — VM/container lifecycle, service API calls |
| **C3 New** | `c3_topology`, `c3_topology_drift`, `c3_topology_security`, `c3_test`, `c3_file`, `c3_report`, `c3_vm_status`, `health_tier1`, `health_tier2`, `health_tier3` | Topology, dynamic tests, file retrieval, tiered health |
| **Front-End** | `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server`, `front_deploy` | 32-project monorepo build, dev servers, CI deploy |
| **Infra** | `list_vms`, `list_services`, `get_service_detail`, `reload_config` | Config introspection from config.json |

**70 Tools** · **9 Resources** (`cloud://config`, `cloud://ssh-config`, `cloud://services-overview`, `cloud://readme`, `cloud://front-projects`, `cloud://c3-api-endpoints`, `cloud://service-apis`, `cloud://services/{name}`, `cloud://vms/{vm_id}`) · **4 Prompts** (`cloud-architect`, `frontend-developer`, `debug-ops`, `crawlee-scraping`)

**Runtime**: `npx tsx` (primary) or Podman/Docker container (fallback)

### Tool Modules

```
src/mcp/tools/
├── infra.ts              # 4 tools — VM/service config introspection
├── repo.ts               # 3 tools — cross-repo file read/search
├── build.ts              # 2 tools — nix build pipeline
├── ssh-tools.ts          # 2 tools — SSH exec, VM health check
├── docker.ts             # 4 tools — container ops via SSH
├── native-ops.ts         # 4 tools — build_ship, docker build, secrets, backup
├── health.ts             # 11 tools — health dashboard, profiling, API discovery
├── control.ts            # 8 tools — VM/container/service lifecycle
├── discovery.ts          # 1 tool  — generic service API proxy
├── cloud.ts              # 7 tools — OCI + GCP cloud operations
├── c3.ts                 # 14 tools — topology, tests, files, tiered health
├── crawlee.ts            # 7 tools — Crawlee Cloud scraping
└── front.ts              # 5 tools — front-end monorepo ops
```

## APIs

| API | URL | Swagger |
|-----|-----|---------|
| **C3 API** (PRIMARY) | `https://api.diegonmarcos.com/c3-api` | `https://api.diegonmarcos.com/c3-api/docs` |
| **Rust API** (LEGACY) | `https://api.diegonmarcos.com/rust-api` | `https://api.diegonmarcos.com/rust-api/docs` |
| **Crawlee API** | `https://api.diegonmarcos.com/crawlee/` | — |

**Cloud CLIs**: `oci`, `gcloud`, `gh`, `terraform` — not covered by MCP.

