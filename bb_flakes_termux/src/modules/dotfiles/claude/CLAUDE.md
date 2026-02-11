# Diego's Master Context for Claude Agents

> **Owner**: Diego Nepomuceno Marcos
> **Updated**: 2026-02-11
> **System**: NixOS (Surface Pro 8) + Kubuntu (dual-boot)
> **Git Root**: `/home/diego/Mounts/Git`

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

## A.2 NixOS Flakes Repository

| Resource | Path |
|----------|------|
| **Unix Repo** | `/home/diego/Mounts/Git/unix` |
| **Surface Host Flake** | `/home/diego/Mounts/Git/unix/aa_nixos-surface_host/` |
| **User Home-Manager** | `/home/diego/Mounts/Git/unix/ba_flakes_desktop/` |

### Flake Structure

```
/home/diego/Mounts/Git/unix/
├── aa_nixos-surface_host/      # NixOS system configuration
│   ├── src/
│   │   ├── flake.nix           # Main flake (nixos-hardware, nixpkgs)
│   │   ├── configuration.nix   # System config (Plasma, GNOME, services)
│   │   ├── hardware-configuration.nix  # LUKS, btrfs, Surface modules
│   │   ├── sessions.nix        # SDDM session definitions
│   │   └── grub-extra-entries.nix
│   └── build.sh                # Interactive build TUI
│
├── ba_flakes_desktop/          # Home-manager standalone configuration
│   ├── src/
│   │   ├── flake.nix           # Main flake with host configs
│   │   ├── hosts/              # Per-host configurations
│   │   ├── modules/            # Profiles, desktop, programs, dotfiles
│   │   └── home-manager/       # Home-manager base config
│   └── build.sh
│
├── bb_flakes_termux/           # Home-manager for Android/Termux
│   ├── src/flake.nix
│   └── build.sh
│
└── [other: ab_arch, ab_kali, ac_win11, ad_ventoy, ae_mobile, da_app_*, de_claude-sandbox]
```

### Home-Manager Profiles (ba_flakes_desktop)

| Profile | File | Packages |
|---------|------|----------|
| `shell-core` | `1-shell-core.nix` | zsh, starship, fzf, ripgrep, fd, bat, eza |
| `dev-languages` | `2-dev-languages.nix` | Node, Python, Rust, Go runtimes |
| `build-debug` | `3-build-debug.nix` | cmake, gcc, gdb, valgrind, strace |
| `containers-cloud` | `4-containers-cloud.nix` | podman, kubectl, helm, gcloud, aws, **oci-cli (pipx)** |
| `security-network` | `5-security-network.nix` | nmap, wireshark, burpsuite, openssl |
| `data-science` | `6-data-science.nix` | jupyter, pandas, numpy, R |
| `productivity` | `7-productivity.nix` | obsidian, zotero, libreoffice |
| `media-graphics` | `8-media-graphics.nix` | gimp, inkscape, ffmpeg, imagemagick |

### Host Configurations

| Config | Profiles | Desktop |
|--------|----------|---------|
| `diego@surface-plasma` | All 8 profiles | Plasma 6 |
| `diego@surface-gnome` | All 8 profiles | GNOME |
| `diego@server` | shell, containers, security | None |
| `diego@cli` | shell, dev-languages | None |
| `diego@minimal` | shell-core only | None |

### Key NixOS Features

- **Impermanence**: Root is tmpfs, `/nix` and `/home/*` are persistent btrfs subvolumes
- **LUKS Encryption**: Full disk encryption with optional USB keyfile unlock
- **Surface Hardware**: Type Cover keyboard, touchscreen, pen via `nixos-hardware`
- **Multi-user**: `diego` (UID 1000), `guest` (UID 1001), cross-OS compatible

### Build Commands

```bash
# Rebuild NixOS system
/home/diego/Mounts/Git/unix/aa_nixos-surface_host/build.sh
# Options: r) rebuild switch, b) build, t) test, 1-4) images

# Rebuild home-manager
/home/diego/Mounts/Git/unix/ba_flakes_desktop/build.sh
```

## A.3 Filesystem Layout

```
/                       # tmpfs (ephemeral, wiped on reboot)
├── nix/                # @nixos/nix subvolume (persistent)
├── home/diego/         # @home-diego subvolume (persistent)
├── home/guest/         # @home-guest subvolume (persistent)
├── mnt/
│   ├── shared/         # @shared subvolume (cross-OS data)
│   ├── btrfs-root/     # Pool root (all subvolumes visible)
│   └── kubuntu/        # Kubuntu ext4 partition (ro)
└── boot/               # Shared boot partition
    └── efi/            # EFI system partition
```

## A.4 Important NixOS Notes

- **initrd modules**: Surface keyboard needs `surface_aggregator`, `surface_hid` loaded early
- **No Intel ISH**: Surface Pro 8 uses SAM, not Intel Integrated Sensor Hub
- **Wayland default**: Plasma 6 on Wayland, X11 available for Openbox
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

## B.2 Cloud Providers

| Provider | Tier | Region | Console |
|----------|------|--------|---------|
| Oracle Cloud | Always Free | eu-marseille-1 | cloud.oracle.com |
| Google Cloud | Free Tier | us-central1 | console.cloud.google.com |
| Cloudflare | Free | Global | dash.cloudflare.com |
| GitHub Pages | Free | Global | github.com |

## B.3 Virtual Machines

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

## B.4 Networking

All VMs connected via **WireGuard mesh** (hub: gcp-proxy 10.0.0.1). All public traffic flows: **Cloudflare → Caddy (gcp-proxy) → WireGuard → target VM**.

Caddy handles automatic HTTPS (Let's Encrypt) and two auth paths:
- **Browser**: Authelia forward-auth (cookie/session + 2FA)
- **CLI/API**: Bearer token via introspect-proxy (OIDC token introspection)

SSH aliases configured in vault: `ssh oci-flex`, `ssh oci-mail`, `ssh oci-analytics`, `ssh gcp-proxy`.

## B.5 Active Services

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

## B.6 Matomo Hybrid Wake/Sleep

oci-analytics (1GB RAM) can't run Matomo + Windmill simultaneously. Matomo uses a hybrid container with supervisord:
- **Awake**: MariaDB + Matomo PHP + Nginx (~160MB). Tracking goes direct to DB.
- **Sleeping**: Only receiver-nginx + receiver-php-fpm (~7MB). Tracking buffered to `/inbox/` JSON files. Wake imports buffered payloads.

```bash
# Toggle via build.sh
~/git/cloud/a_solutions/container-nix/bc-obs_matomo/build.sh wake   # stops windmill, wakes matomo
~/git/cloud/a_solutions/container-nix/bc-obs_matomo/build.sh sleep  # sleeps matomo, starts windmill
```

## B.7 Bearer Token Auth (CLI Access)

All Caddy-protected services accept bearer tokens from Authelia OIDC.

```bash
# Get token (interactive, opens browser for 2FA)
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py

# Use token
TOKEN=$(jq -r .access_token ~/git/vault/A0_keys/providers/authelia/oauth/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://photos.diegonmarcos.com/api/v1/status
```

Token lifetime: 1 year. See `vault/A0_keys/providers/authelia/README.md` for details.

## B.8 IP Change Management

**When VM IPs change, update:**
1. Cloudflare DNS records (Terraform in `ba-clo_cloudflare/`)
2. WireGuard peer endpoints
3. Mailu `PROXY_AUTH_WHITELIST` (if gcp-proxy IP changed)

**DO NOT TOUCH:** iptables, container IPs, Docker networks.

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
cd /home/diego/Mounts/Git/front

./1.ops/build_main.sh           # Interactive TUI
./1.ops/build_main.sh build     # Build all projects
./1.ops/build_main.sh dev       # Start all dev servers
```

Each project has `build.sh` + `build.json` at project root:
```bash
./<category>/<project>/build.sh build    # Build for production
./<category>/<project>/build.sh dev      # Start dev server
```

### Project Folder Structure

```
/project
├── build.sh            # Build engine (universal)
├── build.json          # Build config
├── 0.spec/             # Specs & docs
├── 1.ops/              # Legacy build scripts
├── src_static/ | src/  # Source files
│   ├── scss/           # Sass (ITCSS methodology)
│   ├── typescript/     # TS source
│   └── index.html      # Dev HTML
├── dist/               # Build output
└── public/             # Static assets
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

## F.2 Front-End Projects

| Project | Type | Framework | Port |
|---------|------|-----------|------|
| Landpage | Digital Card | Vanilla | :8000 |
| Linktree | Digital Card | Vanilla | :8001 |
| CV Web | Digital Card | Vanilla | :8002 |
| MyFeed | Dashboard | Vue 3 | :8003 |
| MyGames | Browser Tool | SvelteKit | :8004 |
| Nexus | Digital Card | Vanilla | :8005 |
| Cloud | Dashboard | Vanilla | :8006 |
| Feed Yourself | Browser Tool | Vanilla | :8007 |
| Market Watch | Dashboard | Vanilla | :8010 |
| Central Bank | Browser Tool | Vanilla | :8011 |
| MyProfile | Platform | SvelteKit | :8013 |
| MyMaps | Browser Tool | React+Vite | :8014 |
| MyMovies | Browser Tool | Vue 3 | :8015 |
| MyMusic | Browser Tool | Vue 3 | :8016 |
| JSON Vision | Browser Tool | Vue 3 | :8017 |
| Astro | Browser Tool | Vanilla | :8019 |
| Carto | Browser Tool | Vanilla | :8020 |
| Leafy | Digital Card | Vanilla | :8021 |
| MyTrips | Browser Tool | Vanilla | :8022 |

## F.3 Domains

- **Main**: diegonmarcos.com (Cloudflare DNS)
- **GitHub Pages**: diegonmarcos.github.io

## F.4 Docker Debugging

```bash
docker ps                           # List containers
docker logs --tail 100 <container>  # View logs
docker exec -it <container> bash    # Enter container
docker stats --no-stream            # Container stats
```

## F.5 GitHub CLI

```bash
gh auth status              # Auth status
gh run list                 # List workflow runs
gh run view <run-id> --log  # View logs
gh pr list                  # List PRs
gh pr create                # Create PR
```

## F.6 Important Notes for Claude

1. **Read specs first**: Before modifying any project, read the relevant spec files
2. **Follow code practices**: TypeScript strict mode, Svelte 5 runes, Vue 3 composition API
3. **Build system**: Use `build.sh` scripts, not manual npm commands
4. **Sensitive data**: vault contains credentials - never expose or commit
5. **Analytics**: All web projects must include Matomo tracking
6. **Ports**: Dev servers have assigned ports (8000-8022) - don't conflict
7. **architecture.json**: Source of truth for cloud infrastructure data
