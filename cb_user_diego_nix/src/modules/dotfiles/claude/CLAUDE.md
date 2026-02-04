# Diego's Master Context for Claude Agents

> **Owner**: Diego Nepomuceno Marcos
> **Updated**: 2026-02-04
> **System**: NixOS (Surface Pro 8) + Kubuntu (dual-boot)
> **Git Root**: `/home/diego/Mounts/Git`

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION A: UNIX (NixOS & System Configuration)
# ══════════════════════════════════════════════════════════════════════════════

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
| **User Home-Manager** | `/home/diego/Mounts/Git/unix/cb_user_diego_nix/` |

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
├── cb_user_diego_nix/          # Home-manager standalone configuration
│   ├── src/
│   │   ├── flake.nix           # Main flake with host configs
│   │   ├── hosts/              # Per-host configurations
│   │   │   ├── surface.nix     # Surface-specific (powertop, tlp, syncthing)
│   │   │   ├── server.nix      # Server-specific
│   │   │   └── cli.nix         # CLI-only minimal
│   │   ├── modules/
│   │   │   ├── profiles/       # Tool category profiles (8 profiles)
│   │   │   ├── desktop/        # Desktop environments (Plasma, GNOME)
│   │   │   ├── programs/       # Individual program configs
│   │   │   └── dotfiles/       # Dotfile management
│   │   └── home-manager/       # Home-manager base config
│   └── build.sh
│
└── [other flakes...]           # Container builds, dev shells, etc.
```

### Home-Manager Profiles (cb_user_diego_nix)

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
/home/diego/Mounts/Git/unix/cb_user_diego_nix/build.sh
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

## B.1 Repository & Resources

| Resource | Path | Type |
|----------|------|------|
| **Cloud Repo** | `/home/diego/Mounts/Git/cloud` | Git Repository |
| **Architecture JSON** | `/home/diego/Mounts/Git/cloud/1.ops/cloud_architecture.json` | Source of Truth |
| **Cloud Spec** | `/home/diego/Mounts/Git/cloud/1.ops/Cloud-spec.md` | Documentation |

## B.2 Cloud Providers

| Provider | Tier | Region | Console |
|----------|------|--------|---------|
| Oracle Cloud | Always Free | eu-marseille-1 | cloud.oracle.com |
| Google Cloud | Free Tier | us-central1 | console.cloud.google.com |
| Cloudflare | Free | Global | dash.cloudflare.com |
| GitHub Pages | Free | Global | github.com |

## B.3 Virtual Machines

### Always-On (24/7) - Free Tier
| VM ID | Provider | IP | RAM | Services | Cost |
|-------|----------|-----|-----|----------|------|
| oci-f-micro_1 | Oracle | 130.110.251.193 | 1 GB | Mailu Mail | $0 |
| oci-f-micro_2 | Oracle | 129.151.228.66 | 1 GB | Matomo Analytics | $0 |
| gcp-f-micro_1 | GCloud | 35.226.147.64 | 1 GB | NPM, Authelia, ntfy, NocoDB | $0 |

### Wake-on-Demand - Paid
| VM ID | Provider | IP | RAM | Services | Cost |
|-------|----------|-----|-----|----------|------|
| oci-p-flex_1 | Oracle | 144.24.196.72 | 8 GB | Photoprism, Radicale, Syncthing | $5.50/mo |

**Wake-on-Demand Services** (on oci-p-flex_1):
- Photoprism (photos.diegonmarcos.com)
- Radicale Calendar (cal.diegonmarcos.com)
- Code Server IDE (ide.diegonmarcos.com)

## B.4 Wake-on-Demand (Flex VM)

The paid flex VM (`oci-p-flex_1`) is stopped when idle to save costs. It auto-stops after 30 minutes of inactivity.

### Wake Up Methods

**1. Via Cloud Dashboard UI:**
- Go to https://cloud.diegonmarcos.com
- Click the VM control buttons (Start/Stop/Reboot)

**2. Via OCI CLI:**
```bash
# Start the flex VM
oci compute instance action --action START \
  --instance-id <INSTANCE_OCID>

# Stop the flex VM
oci compute instance action --action STOP \
  --instance-id <INSTANCE_OCID>

# Check status
oci compute instance get --instance-id <INSTANCE_OCID> \
  --query 'data."lifecycle-state"'
```

**3. Via API (Flask endpoint on GCloud):**
```bash
# Wake up
curl -X POST https://api.diegonmarcos.com/vm/flex/start

# Stop
curl -X POST https://api.diegonmarcos.com/vm/flex/stop

# Status
curl https://api.diegonmarcos.com/vm/flex/status
```

**4. Via Linktree UI:**
- The Linktree DEVING card has VM control buttons
- Shows live status indicator (green=running, red=stopped)

## B.5 Active Services

| Service | Domain | VM | Availability |
|---------|--------|-----|--------------|
| Matomo Analytics | analytics.diegonmarcos.com | oci-f-micro_2 | 24/7 |
| Mailu Mail | mail.diegonmarcos.com | oci-f-micro_1 | 24/7 |
| NPM Proxy | proxy.diegonmarcos.com | gcp-f-micro_1 | 24/7 |
| Authelia 2FA | auth.diegonmarcos.com | gcp-f-micro_1 | 24/7 |
| ntfy Push | rss.diegonmarcos.com | gcp-f-micro_1 | 24/7 |
| NocoDB | db.diegonmarcos.com | gcp-f-micro_1 | 24/7 |
| Cloud Dashboard | cloud.diegonmarcos.com | GitHub Pages | 24/7 |
| Photoprism | photos.diegonmarcos.com | oci-p-flex_1 | wake |
| Radicale Calendar | cal.diegonmarcos.com | oci-p-flex_1 | wake |
| Code Server IDE | ide.diegonmarcos.com | oci-p-flex_1 | wake |

## B.6 SSH Access

```bash
# Oracle Micro 1 (Mail)
ssh -i /home/diego/Mounts/Git/vault/A0_keys/ssh/id_rsa ubuntu@130.110.251.193

# Oracle Micro 2 (Analytics)
ssh -i /home/diego/Mounts/Git/vault/A0_keys/ssh/id_rsa ubuntu@129.151.228.66

# GCloud (Proxy)
gcloud compute ssh arch-1 --zone us-central1-a

# Oracle Flex 1 (Wake-on-Demand)
ssh -i /home/diego/Mounts/Git/vault/A0_keys/ssh/id_rsa ubuntu@144.24.196.72
```

## B.7 IP Change Management (CRITICAL)

**When VM IPs change, ONLY update:**
1. Cloudflare DNS records
2. NPM Proxy Host forward addresses
3. Mailu `PROXY_AUTH_WHITELIST` (if GCloud IP changed)
4. WireGuard peer endpoints (if needed)

**DO NOT TOUCH:**
- iptables rules (Docker manages automatically)
- Container IP addresses
- Docker network configurations

**If something breaks:** `sudo systemctl restart docker`

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION C: SECURITY & CREDENTIALS
# ══════════════════════════════════════════════════════════════════════════════

## C.1 Vault Repository

| Resource | Path |
|----------|------|
| **Vault Repo** | `/home/diego/Mounts/Git/vault` |

**WARNING**: This repository contains sensitive credentials. NEVER expose or commit to public repos.

## C.2 Vault Structure

```
/home/diego/Mounts/Git/vault/
├── A0_keys/                  # Machine credentials
│   ├── ssh/                  # SSH keys (symlinked to ~/.ssh/)
│   ├── wireguard/            # VPN keys
│   ├── oci/                  # Oracle Cloud CLI config
│   ├── gcloud/               # Google Cloud CLI config
│   ├── github/               # GitHub CLI tokens
│   └── api_tokens.json       # Cloud service API credentials
├── A1_bitwarden/             # Bitwarden vault backup
├── A2_2fa/                   # TOTP seeds + recovery codes
├── A3_gpg/                   # GPG encryption keys
├── A4_certificates/          # Manual SSL certificates
├── B0_ID/                    # Identity documents
├── B1_Payment/               # Payment card info
└── B2_Notes/                 # Secure notes
```

## C.3 Security Stack

| Layer | Components |
|-------|------------|
| **Network Edge** | Cloud Firewalls, UFW |
| **Traffic** | NPM Reverse Proxy, TLS/SSL (Let's Encrypt) |
| **Authentication** | Authelia 2FA, OIDC |
| **Application** | Docker Networks, Container Isolation |
| **Credentials** | Bitwarden (passwords), Aegis (TOTP) |

## C.4 CLI Authentication

```bash
# GitHub CLI
gh auth status

# Oracle Cloud CLI
oci session authenticate

# Google Cloud CLI
gcloud auth login
```

---

# ══════════════════════════════════════════════════════════════════════════════
# SECTION D: OPS & BEST PRACTICES
# ══════════════════════════════════════════════════════════════════════════════

## D.1 Working Directory Rule

**ALL Claude Code sessions MUST start from `~/.claude` directory.**
This ensures consistent context loading and access to CLAUDE.md instructions.

## D.2 Front-End Development

### Repository & Resources

| Resource | Path |
|----------|------|
| **Front Repo** | `/home/diego/Mounts/Git/front` |
| **Stack Spec** | `/home/diego/Mounts/Git/front/1.ops/00_Stack_Main.md` |
| **Code Practices** | `/home/diego/Mounts/Git/front/1.ops/30_Code_Practise.md` |
| **Master Build** | `/home/diego/Mounts/Git/front/1.ops/build_main.sh` |

### Build System

```bash
cd /home/diego/Mounts/Git/front

./1.ops/build_main.sh           # Interactive TUI
./1.ops/build_main.sh build     # Build all projects
./1.ops/build_main.sh dev       # Start all dev servers
```

Each project has `<project>/1.ops/build.sh`:
```bash
./1.ops/build.sh build    # Build for production
./1.ops/build.sh dev      # Start dev server
```

### Project Folder Structure

```
/project
├── 0.spec/             # Specs & docs
├── 1.ops/              # Build scripts (build.sh)
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

## D.5 Dependency Verification (CRITICAL)

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
# SECTION E: OTHERS (Quick Reference)
# ══════════════════════════════════════════════════════════════════════════════

## E.1 Primary Paths

| Area | Path |
|------|------|
| Git Root | `/home/diego/Mounts/Git` |
| Front-end | `/home/diego/Mounts/Git/front` |
| Cloud Backend | `/home/diego/Mounts/Git/cloud` |
| Unix/NixOS | `/home/diego/Mounts/Git/unix` |
| Security Vault | `/home/diego/Mounts/Git/vault` |

## E.2 Front-End Projects

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

## E.3 Domains

- **Main**: diegonmarcos.com (Cloudflare DNS)
- **GitHub Pages**: diegonmarcos.github.io

## E.4 Docker Debugging

```bash
docker ps                           # List containers
docker logs --tail 100 <container>  # View logs
docker exec -it <container> bash    # Enter container
docker stats --no-stream            # Container stats
```

## E.5 GitHub CLI

```bash
gh auth status              # Auth status
gh run list                 # List workflow runs
gh run view <run-id> --log  # View logs
gh pr list                  # List PRs
gh pr create                # Create PR
```

## E.6 Important Notes for Claude

1. **Read specs first**: Before modifying any project, read the relevant spec files
2. **Follow code practices**: TypeScript strict mode, Svelte 5 runes, Vue 3 composition API
3. **Build system**: Use `./1.ops/build.sh` scripts, not manual npm commands
4. **Sensitive data**: vault contains credentials - never expose or commit
5. **Analytics**: All web projects must include Matomo tracking
6. **Ports**: Dev servers have assigned ports (8000-8017) - don't conflict
7. **architecture.json**: Source of truth for cloud infrastructure data
