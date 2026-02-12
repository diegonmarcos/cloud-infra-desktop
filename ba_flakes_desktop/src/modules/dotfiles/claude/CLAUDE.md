# Diego's Master Context for Claude Agents

> **Owner**: Diego Nepomuceno Marcos
> **Updated**: 2026-02-12
> **System**: NixOS (Surface Pro 8) + Kubuntu (dual-boot)
> **Git Root**: `/home/diego/Mounts/Git`

---

## Table of Contents

### STACK
- [A. UNIX (NixOS & System Configuration)](#section-a-unix-nixos--system-configuration)
- [B. CLOUD INFRASTRUCTURE](#section-b-cloud-infrastructure)
- [C. SECURITY & CREDENTIALS](#section-c-security--credentials)
- [D. FRONT-END DEVELOPMENT](#section-d-front-end-development)
- [E. OPS & BUILD SYSTEM](#section-e-ops--build-system)
- [F. OTHERS (Quick Reference)](#section-f-others-quick-reference)

### SKILLS & MCPs
- [I. Skills Senior](#i-skills-senior)
  - [I.1 Cloud Architect Senior](#i1-cloud-architect-senior)
  - [I.2 Software Engineer Senior](#i2-software-engineer-senior)
  - [I.3 Software Architecture Senior](#i3-software-architecture-senior)
  - [I.4 Front-End Developer Senior](#i4-front-end-developer-senior)
  - [I.5 Designer Senior](#i5-designer-senior)
- [II. Skills Junior](#ii-skills-junior)
  - [II.1 Software Engineer](#ii1-software-engineer)
  - [II.2 Ops](#ii2-ops)
- [III. MCPs](#iii-mcps)
- [IV. APIs](#iv-apis)

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
| **Secondary OS** | Kubuntu (dual-boot, ext4 partition) |
| **Kernel** | linux-surface (mainline 6.15+ with Surface patches) |
| **Desktop** | KDE Plasma 6 (Wayland), GNOME, Openbox available |
| **Shell** | Fish (default), Zsh, Bash available |

## A.2 Key Paths & Build

| Resource | Path |
|----------|------|
| **Unix Repo** | `/home/diego/Mounts/Git/unix` |
| **Surface Host Flake** | `unix/aa_nixos-surface_host/` |
| **Home-Manager Desktop** | `unix/ba_flakes_desktop/` |
| **Home-Manager Termux** | `unix/bb_flakes_termux/` |

```bash
# Rebuild NixOS system
~/git/unix/aa_nixos-surface_host/build.sh    # Options: r) switch, b) build, t) test

# Rebuild home-manager
~/git/unix/ba_flakes_desktop/build.sh        # Desktop
~/git/unix/bb_flakes_termux/build.sh         # Termux
```

**Host Configs**: `surface-plasma` (all 8 profiles + Plasma 6), `surface-gnome`, `server`, `cli`, `minimal`.

## A.3 Agent-Essential Notes

- **Impermanence**: Root is tmpfs — `/nix` and `/home/*` are persistent btrfs subvolumes
- **LUKS**: Full disk encryption, USB keyfile with password fallback
- **initrd**: Surface keyboard needs `surface_aggregator`, `surface_hid` loaded early
- **No Intel ISH**: Surface Pro 8 uses SAM, not Intel Integrated Sensor Hub
- **Docker/Podman**: Data stored in `/mnt/shared/data/containers/`

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION B: CLOUD INFRASTRUCTURE
# ══════════════════════════════════════════════════════════════════════════════

> **Full documentation**: See `~/git/cloud/README.md`

## B.1 Repository & Resources

| Resource | Path | Type |
|----------|------|------|
| **Cloud Repo** | `/home/diego/Mounts/Git/cloud` | Git Repository |
| **Container Configs** | `/home/diego/Mounts/Git/cloud/a_solutions/container-nix/` | Nix Flakes |
| **Home Manager** | `/home/diego/Mounts/Git/cloud/a_solutions/home-manager/` | VM Configs |

## B.2 Virtual Machines

### Always-On (24/7) - Free Tier
| VM | Alias | IP | WG IP | RAM | Services |
|----|-------|-----|-------|-----|----------|
| gcp-f-micro_1 | gcp-proxy | 35.226.147.64 | 10.0.0.1 | 1 GB | Caddy, Authelia, introspect-proxy, Vaultwarden, ntfy |
| oci-f-micro_1 | oci-mail | 130.110.251.193 | 10.0.0.3 | 1 GB | Mailu, Syncthing, Radicale |
| oci-f-micro_2 | oci-analytics | 129.151.228.66 | 10.0.0.4 | 1 GB | Matomo (hybrid wake/sleep), Windmill |

### Wake-on-Demand - Paid
| VM | Alias | IP | WG IP | RAM | Services |
|----|-------|-----|-------|-----|----------|
| oci-p-flex_1 | oci-flex | 144.24.196.72 | 10.0.0.2 | 8 GB | PhotoPrism, NocoDB, Code Server, AFFiNE |

## B.3 Networking

Traffic flow: **Cloudflare → Caddy (gcp-proxy) → WireGuard → target VM**. Auth: Authelia 2FA (browser) or Bearer token via introspect-proxy (CLI/API).

SSH aliases: `ssh oci-flex`, `ssh oci-mail`, `ssh oci-analytics`, `ssh gcp-proxy`.

## B.4 Active Services

| Service | Domain | VM | Port | Availability |
|---------|--------|-----|------|--------------|
| Caddy Proxy | proxy.diegonmarcos.com | gcp-proxy | 80/443 | 24/7 |
| Authelia 2FA | auth.diegonmarcos.com | gcp-proxy | 9091 | 24/7 |
| Vaultwarden | vault.diegonmarcos.com | gcp-proxy | 80 | 24/7 |
| ntfy Push | rss.diegonmarcos.com | gcp-proxy | 8090 | 24/7 |
| API (Flask+Rust) | api.diegonmarcos.com | gcp-proxy | 5000/8080 | 24/7 |
| Mailu Mail | mail.diegonmarcos.com | oci-mail | 8444 | 24/7 |
| Syncthing | sync.diegonmarcos.com | oci-mail | 8384 | 24/7 |
| Radicale Calendar | cal.diegonmarcos.com | oci-mail | 5232 | 24/7 |
| Matomo Analytics | analytics.diegonmarcos.com | oci-analytics | 8080 | 24/7 (hybrid) |
| Windmill | — | oci-analytics | — | 24/7 (toggles with Matomo) |
| PhotoPrism | photos.diegonmarcos.com | oci-flex | 3013 | wake-on-demand |
| NocoDB | db.diegonmarcos.com | oci-flex | 8085 | wake-on-demand |
| Code Server | ide.diegonmarcos.com | oci-flex | 8443 | wake-on-demand |
| AFFiNE | drive-notes-affine.diegonmarcos.com | oci-flex | 3010 | wake-on-demand |

## B.5 Bearer Token Auth (CLI Access)

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
| **Vault Repo** | `/home/diego/Mounts/Git/vault` |

**WARNING**: Contains sensitive credentials. NEVER expose or commit to public repos.

## C.2 Vault Structure

```
/home/diego/Mounts/Git/vault/
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
| **Front Repo** | `/home/diego/Mounts/Git/front` |
| **Stack Spec** | `/home/diego/Mounts/Git/front/1.ops/00_Stack_Main.md` |
| **Code Practices** | `/home/diego/Mounts/Git/front/1.ops/30_Code_Practise.md` |
| **Master Build** | `/home/diego/Mounts/Git/front/1.ops/build_main.sh` |

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
╚══════════════════════════════════════════════════════════════════╝
```

### Build Pattern per Repository

| Repo | Pattern | What build.sh does |
|------|---------|-------------------|
| **front/** | `build.sh` + `build.json` per project | Sass/TS/Vite/SvelteKit build, dev server, deploy to GitHub Pages |
| **cloud/** | `build.sh` + `build.json` per service (Nix flake → Docker Compose) | `build` generates docker-compose.yml, `ship` deploys to VM via SSH |
| **unix/** | `build.sh` per flake (NixOS host, home-manager desktop/termux) | `switch` applies NixOS/home-manager config, `build` builds without applying |

**All three repos follow the same interface**: `build.sh <command>`. NEVER bypass it with raw `npm`, `nix`, `docker-compose`, or other commands.

## E.1 Working Directory Rule

**ALL Claude Code sessions MUST start from `~/.claude` directory.**
This ensures consistent context loading and access to CLAUDE.md instructions.

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

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION F: OTHERS (Quick Reference)
# ══════════════════════════════════════════════════════════════════════════════

## F.1 Primary Paths

| Area | Path |
|------|------|
| Git Root | `/home/diego/Mounts/Git` |
| Front-end | `/home/diego/Mounts/Git/front` |
| Cloud Backend | `/home/diego/Mounts/Git/cloud` |
| Unix/NixOS | `/home/diego/Mounts/Git/unix` |
| Security Vault | `/home/diego/Mounts/Git/vault` |

## F.2 Domains

- **Main**: diegonmarcos.com (Cloudflare DNS)
- **GitHub Pages**: diegonmarcos.github.io

## F.3 Important Notes for Claude

1. **Read specs first**: Before modifying any project, read the relevant spec files
2. **Follow code practices**: TypeScript strict mode, Svelte 5 runes, Vue 3 composition API
3. **Build system**: Use `build.sh` scripts, not manual npm commands
4. **Sensitive data**: vault contains credentials - never expose or commit
5. **Analytics**: All web projects must include Matomo tracking
6. **Ports**: Dev servers have assigned ports (8000-8022) - don't conflict
7. **architecture.json**: Source of truth for cloud infrastructure data

---

# ████████████████████████████████████████████████████████████████████████████
#                           SKILLS & MCPs
# ████████████████████████████████████████████████████████████████████████████

---

# I. Skills Senior

## I.1 Cloud Architect Senior

**Brief**: Designs and manages the 4-VM cloud infrastructure — WireGuard mesh, Caddy reverse proxy, Authelia 2FA, 43 containerized services across OCI and GCP free tiers. Handles VM lifecycle, networking, DNS (Terraform), and cost optimization.

**Skill**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Flask API | `/vms`, `/vms/{id}/status`, `/vms/{id}/start`, `/vms/{id}/stop`, `/vms/{id}/reset`, `/services`, `/services/{id}`, `/dashboard/summary`, `/wake/trigger`, `/wake/status`, `/providers`, `/domains` |
| MCP | OCI CLI | `oci compute instance action` (start/stop/reset) |
| MCP | gcloud CLI | `gcloud compute instances start/stop/reset` |
| MCP | Cloudflare | Terraform via `ba-clo_cloudflare/build.sh` |
| Direct | SSH | All 4 VMs (Docker, system commands, build.sh) |
| Direct | WireGuard | 10.0.0.0/24 mesh (inter-VM communication) |

---

## I.2 Software Engineer Senior

**Brief**: Full-stack development across all repos — Rust API (gcp-proxy), Flask API, MCP server (TypeScript/Node), Nix flake configurations, Python tooling. Writes production code, reviews architecture, manages dependencies.

**Skill**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Flask API | `/health`, `/config`, all CRUD endpoints |
| MCP | Rust API | `api.diegonmarcos.com:8080` (replacing Flask) |
| MCP | Repo tools | `read_file`, `search_repos`, `list_directory` across all 5 repos |
| MCP | Build tools | `build_service`, `build_all` |
| Direct | GitHub CLI | `gh pr`, `gh run`, `gh api` |
| Direct | npm/node | Package management, build toolchain |
| Direct | Cargo/rustc | Rust compilation (`--jobs 1` on micro VMs) |

---

## I.3 Software Architecture Senior

**Brief**: System design and Nix flake architecture — repo structure, module organization, build.sh engine design, flake composition (NixOS host, home-manager desktop/termux, cloud home-manager). Defines project archetypes and enforces the Nix Way.

**Skill**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Repo tools | `read_file`, `search_repos`, `list_directory` (all repos) |
| MCP | Flask API | `/config`, `/cloud_control/infrastructure` |
| Direct | Nix CLI | `nix flake show`, `nix flake metadata` (via build.sh only) |
| Direct | Git | Cross-repo structure analysis |

---

## I.4 Front-End Developer Senior

**Brief**: Develops and maintains the 32-project front-end monorepo — TypeScript strict mode, Svelte 5 runes, Vue 3 composition API, SCSS/ITCSS. Manages build system (build.sh + build.json), dev servers, GitHub Pages CI/CD pipeline.

**Skill**: `~/git/front/b_Work_Tools/skills_mcp/0.spec/skills.md` (frontend-developer persona)

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Front tools | `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server`, `front_deploy` |
| MCP | Repo tools | `read_file`, `search_repos` (front repo) |
| Direct | Matomo | `analytics.diegonmarcos.com/js/container_odwLIyPV.js` (tracking) |
| Direct | GitHub Actions | `.github/workflows/deploy.yml` (conditional per-project builds) |
| Direct | GitHub Pages | `diegonmarcos.github.io/*` (deployment target) |
| Direct | NocoDB | `db.diegonmarcos.com` (data backend for some projects) |
| Direct | PhotoPrism | `photos.diegonmarcos.com/api/v1/` (photo data for myphotos) |

---

## I.5 Designer Senior

**Brief**: UI/UX design and visual implementation — SCSS architecture (ITCSS), responsive breakpoints, accessibility (WCAG), semantic HTML, no-inline-CSS enforcement. Designs component layouts, color systems, and typography across all 32 projects.

**Skill**: `~/git/front/b_Work_Tools/skills_mcp/0.spec/skills.md` (ui-designer / ux-researcher persona)

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Front tools | `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server` |
| MCP | Repo tools | `read_file` (SCSS files, HTML templates) |
| Direct | Google Fonts | Font loading via `<link>` |
| Direct | CDN assets | Icons, images from `public/` directories |

---

# II. Skills Junior

## II.1 Software Engineer

**Brief**: Handles basic coding tasks — bug fixes, small features, test writing, documentation updates. Works within existing patterns without architectural decisions. Follows established code standards (TS strict, Svelte runes, Vue composition).

**Skill**: `~/git/front/b_Work_Tools/skills_mcp/0.spec/skills.md` (rapid-prototyper persona)

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Repo tools | `read_file`, `search_repos`, `list_directory` |
| MCP | Front tools | `front_get_project`, `front_build`, `front_dev_server` |
| Direct | GitHub CLI | `gh pr create`, `gh run list` |

---

## II.2 Ops

**Brief**: Handles operational tasks — Docker container management, log inspection, service restarts, VM health checks, backup verification. Executes established runbooks without infrastructure changes.

**Skill**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/SKILL.md`

**MCPs used**: `cloud-infra`

**APIs**:
| Source | API | Endpoints Used |
|--------|-----|----------------|
| MCP | Docker tools | `docker_ps`, `docker_control`, `docker_logs`, `docker_compose_up` |
| MCP | SSH tools | `ssh_exec`, `check_vm` |
| MCP | Flask API | `/vms/{id}/status`, `/vms/{id}/containers`, `/dashboard/quick-status` |
| MCP | Build tools | `build_service` (rebuild containers) |
| Direct | SSH | Log tailing, systemd service management |

---

# III. MCPs

## III.1 cloud-infra

| Field | Value |
|-------|-------|
| **Name** | `cloud-infra` |
| **Version** | `1.0.0` |
| **Transport** | stdio |
| **Runtime** | Node.js (TypeScript) |
| **Repo** | `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/` |
| **Entry** | `src/index.ts` |
| **SDK** | `@modelcontextprotocol/sdk ^1.12.0` |

### Tools (21)

| Category | Tool | Description |
|----------|------|-------------|
| **Infra** | `list_vms` | List all 4 VMs with IPs, aliases, descriptions |
| **Infra** | `list_services` | List 42+ services (filter by VM or category) |
| **Infra** | `get_service_detail` | Full service info: flake.nix, secrets, dist files |
| **Repo** | `read_file` | Read file from any repo (cloud, unix, vault, front, tools) |
| **Repo** | `search_repos` | Grep across repositories |
| **Repo** | `list_directory` | List directory contents |
| **Build** | `build_service` | Run build.sh for a service (build/secrets/ship/clean/all) |
| **Build** | `build_all` | Run root orchestrator for all services |
| **SSH** | `ssh_exec` | Execute command on VM via SSH |
| **SSH** | `check_vm` | Test VM reachability + system info |
| **Docker** | `docker_ps` | List containers on a VM |
| **Docker** | `docker_control` | Start/stop/restart container |
| **Docker** | `docker_logs` | Get container logs |
| **Docker** | `docker_compose_up` | Rebuild + restart service on its VM |
| **API** | `api_call` | Call any Flask API endpoint |
| **API** | `api_vm_control` | Start/stop/reset VM via OCI/gcloud CLI |
| **Front** | `front_list_projects` | List all 32 web projects |
| **Front** | `front_get_project` | Full project detail: build.json, deps, dist, dev server |
| **Front** | `front_build` | Build a project using universal build.sh |
| **Front** | `front_dev_server` | Start/stop/status of project dev server |
| **Front** | `front_deploy` | Run deploy.sh (merge deps + build all changed) |

### Resources (5)

| URI | Description |
|-----|-------------|
| `cloud://config` | Full infrastructure config (config.json) |
| `cloud://ssh-config` | SSH configuration file |
| `cloud://services-overview` | Services overview markdown table |
| `cloud://readme` | Container-nix README |
| `cloud://front-projects` | Front-end projects overview |

### Prompts (1)

| Name | Description |
|------|-------------|
| `cloud-architect` | Full cloud architect persona with VM table, services, architecture, and operational principles |

---

# IV. APIs

## IV.1 Rust API — `https://api.diegonmarcos.com:8080` (PRIMARY)

Axum + utoipa server on gcp-proxy. 47 endpoints focused on VM/container control and health monitoring.

**Swagger docs**: `https://api.diegonmarcos.com:8080/rust/api-docs`

**Repo**: `~/git/cloud/a_solutions/container-nix/bb-sec_rust-api/`

### Generic Engine Endpoints (GET)

| Endpoint | Description |
|----------|-------------|
| `/rust/health` | API alive check |
| `/rust/health/all` | Full health summary (all VMs + containers) |
| `/rust/health/containers-by-vm` | Container status grouped by VM |
| `/rust/health/containers-by-service` | Container status grouped by service |
| `/rust/health/proxied-by-services` | Proxied service health checks |
| `/rust/health/resources-all` | Resource usage (CPU, RAM, disk) all VMs |
| `/rust/health/ids` | List all VM and container IDs |
| `/rust/health/{vm_id}` | Health for a specific VM |
| `/rust/health/{vm_id}/{container_name}` | Status for a specific container |

### Generic Engine Endpoints (POST)

| Endpoint | Description |
|----------|-------------|
| `/rust/vms/{vm_id}/start` | Start a VM |
| `/rust/vms/{vm_id}/stop` | Stop a VM |
| `/rust/vms/{vm_id}/reset` | Reset/reboot a VM |
| `/rust/vms/{vm_id}/containers/{name}/start` | Start container on VM |
| `/rust/vms/{vm_id}/containers/{name}/stop` | Stop container on VM |
| `/rust/vms/{vm_id}/containers/{name}/restart` | Restart container on VM |
| `/rust/vms/{vm_id}/services/{service}/start` | Start service on VM |
| `/rust/vms/{vm_id}/services/{service}/stop` | Stop service on VM |

## IV.2 Flask API — `https://api.diegonmarcos.com` (port 5000) — STALE BACKUP

**Being replaced by Rust API.** Flask API is kept as a reference implementation for porting endpoints to Rust. Use Rust API for all new work.

**Swagger docs**: `https://api.diegonmarcos.com/docs`

**Repo**: `~/git/cloud/a_solutions/container-nix/bb-sec_flask-api/`

## IV.3 Cloud Provider CLIs (not covered by MCP directly)

| CLI | Auth | Usage |
|-----|------|-------|
| `oci` | Session token | `oci compute instance action --action START --instance-id <ocid>` |
| `gcloud` | Service account | `gcloud compute instances start <name> --zone <zone>` |
| `gh` | OAuth token | `gh api`, `gh pr`, `gh run` |
| `terraform` | Cloudflare API token | DNS record management in `ba-clo_cloudflare/` |

## IV.4 Service APIs (not covered by MCP)

| Service | Base URL | Auth | Usage |
|---------|----------|------|-------|
| PhotoPrism | `photos.diegonmarcos.com/api/v1/` | Bearer token | Photo management, album API |
| NocoDB | `db.diegonmarcos.com/api/v1/` | Bearer token | Database CRUD, table API |
| Matomo | `analytics.diegonmarcos.com/` | Token auth | Reporting API, tracking API |
| Vaultwarden | `vault.diegonmarcos.com/api/` | Bearer token | Password vault API |
| Syncthing | `sync.diegonmarcos.com/rest/` | API key | Folder/device management |
| Radicale | `cal.diegonmarcos.com/` | Basic auth | CalDAV/CardDAV |
| ntfy | `rss.diegonmarcos.com/` | Bearer token | Push notifications |
| Mailu | `mail.diegonmarcos.com/api/v1/` | API key | Mail admin API |
| AFFiNE | `drive-notes-affine.diegonmarcos.com/` | Session | Workspace API |
| Authelia | `auth.diegonmarcos.com/api/` | Session/OIDC | Auth status, OIDC endpoints |
| Windmill | Internal only | — | Workflow execution API |
