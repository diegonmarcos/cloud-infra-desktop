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

> **Full documentation**: See `~/git/front/b_Work_Tools/skills_mcp/README.md`
> **Individual docs**: See `~/git/front/b_Work_Tools/skills_mcp/docs/`

## Skills Summary

| Level | Skill | Brief | Skill File |
|-------|-------|-------|------------|
| Senior | Cloud Architect | 4-VM infra, WireGuard, Caddy, Authelia, 43 services | `cloud/.../bb-sec_mcp-server-skills/SKILL.md` |
| Senior | Software Engineer | Full-stack — Rust API, Flask, MCP server, Nix, Python | `cloud/.../bb-sec_mcp-server-skills/SKILL.md` |
| Senior | Software Architecture | System design, Nix flake composition, build.sh engine | `cloud/.../bb-sec_mcp-server-skills/SKILL.md` |
| Senior | Front-End Developer | 32-project monorepo, TS strict, Svelte 5, Vue 3, SCSS | `front/.../skills_mcp/0.spec/skills.md` |
| Senior | Designer | ITCSS, responsive, WCAG, semantic HTML, no-inline-CSS | `front/.../skills_mcp/0.spec/skills.md` |
| Junior | Software Engineer | Bug fixes, small features, follows existing patterns | `front/.../skills_mcp/0.spec/skills.md` |
| Junior | Ops | Docker management, logs, restarts, health checks | `cloud/.../bb-sec_mcp-server-skills/SKILL.md` |

All skills use the `cloud-infra` MCP.

## MCP: cloud-infra

**Repo**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/` | **SDK**: `@modelcontextprotocol/sdk ^1.12.0`

**21 Tools**: `list_vms`, `list_services`, `get_service_detail`, `read_file`, `search_repos`, `list_directory`, `build_service`, `build_all`, `ssh_exec`, `check_vm`, `docker_ps`, `docker_control`, `docker_logs`, `docker_compose_up`, `api_call`, `api_vm_control`, `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server`, `front_deploy`

**5 Resources**: `cloud://config`, `cloud://ssh-config`, `cloud://services-overview`, `cloud://readme`, `cloud://front-projects`

**1 Prompt**: `cloud-architect`

## APIs

| API | URL | Swagger |
|-----|-----|---------|
| **Rust API** (PRIMARY) | `https://api.diegonmarcos.com:8080` | `https://api.diegonmarcos.com:8080/rust/api-docs` |
| **Flask API** (STALE) | `https://api.diegonmarcos.com` | `https://api.diegonmarcos.com/docs` |

**Cloud CLIs**: `oci`, `gcloud`, `gh`, `terraform` — not covered by MCP.

**Service APIs**: PhotoPrism, NocoDB, Matomo, Vaultwarden, Syncthing, Radicale, ntfy, Mailu, AFFiNE, Authelia, Windmill — see `docs/apis/service-apis.md`.
