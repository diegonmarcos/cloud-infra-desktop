# B_APPS - Containerized App Profiles

> Unified builder for Docker, Podman, or host installation

---

## Overview

B_APPS provides curated package sets for development containers with two profiles:

| Profile | Image Size | Export | Use Case |
|---------|-----------|--------|----------|
| **min** | ~5 GB | ~5 GB | CLI power user, privacy tools, modern shell, AI tools |
| **basic** | ~6 GB | ~6 GB | min + compilers, VNC desktop, LibreOffice |

---

## Profile Comparison

### min (Recommended for CLI work)

| Category | Packages |
|----------|----------|
| **Base** | base-devel, git, sudo, curl, wget |
| **Shell** | bash, zsh, fish, vim, htop, jq, tree, bc, gawk |
| **Modern CLI** | eza, bat, fd, ripgrep, fzf, zoxide, starship |
| **Network** | iproute2, bind (dig/nslookup), net-tools, openssh |
| **Privacy** | tor, torsocks, dnscrypt-proxy, wireguard, openvpn |
| **Languages** | nodejs, npm, python, pip, pipx, rust |
| **GUI** | konsole, falkon, dolphin, okular |
| **AI Tools** | claude-code, gemini-cli |

### basic (min + development)

| Category | Additional Packages |
|----------|---------------------|
| **Compilers** | gcc, clang, cmake, ninja, make, rustup, go |
| **Languages** | pnpm (replaces npm) |
| **Sandbox** | firejail, flatpak |
| **Desktop** | xorg-server, openbox, dmenu, tigervnc |
| **GUI** | libreoffice-fresh |

---

## Resource Usage

### Container Image Sizes

| Profile | Image | Export (.tar) |
|---------|-------|---------------|
| min | ~5 GB | ~5 GB |
| basic | ~6 GB | ~6 GB |

### Runtime Memory (idle container)

| Profile | RAM Usage |
|---------|-----------|
| min | ~50 MB |
| basic | ~80 MB |

### Storage by Category (approximate)

| Category | Size |
|----------|------|
| Base system (Arch) | ~400 MB |
| Rust toolchain | ~300 MB |
| Node.js + npm | ~80 MB |
| Python + pip | ~100 MB |
| Qt/KDE libs | ~500 MB |
| Breeze icons | ~200 MB |
| LibreOffice | ~800 MB |
| GCC/Clang | ~500 MB |
| Xorg + VNC | ~150 MB |

---

## Usage

### Build Commands

```bash
# Interactive TUI
./build.sh

# Direct build
./build.sh podman min      # Build minimal Podman image
./build.sh podman basic    # Build basic Podman image
./build.sh docker min      # Build minimal Docker image
./build.sh host full       # Install full profile on host
```

### Run Container

```bash
# CLI only
podman run -it b_apps:min

# With X11 forwarding
podman run -it -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix b_apps:min

# With VNC (basic/full)
podman run -d -p 5901:5901 b_apps:basic
# Connect to localhost:5901
```

### Export/Import

```bash
# Export
podman save -o b_apps-min.tar localhost/b_apps:min

# Import on another system
podman load -i b_apps-min.tar
```

---

## Package Configuration

Profiles are defined in `apps_profiles/*.conf`:

```
apps_profiles/
├── min.conf      # Minimal profile
├── basic.conf    # Basic profile (includes min)
```

### Config Format

```bash
# CATEGORY_DISTRO="package1 package2 ..."
BASE_arch="base-devel git sudo curl wget"
BASE_fedora="@development-tools git sudo curl wget"
BASE_debian="build-essential git sudo curl wget"
```

---

## Output Locations

| Target | Location |
|--------|----------|
| Source | `src_podman/`, `src_docker/`, `src_host/` |
| Output | `/shared/@images/b_apps/dist_*` |

---

## AI Tools Included

Both profiles include npm global packages:

| Tool | Description |
|------|-------------|
| `claude-code` | Anthropic Claude CLI |
| `gemini-cli` | Google Gemini CLI |

---

## Notes

- Base image: `docker.io/archlinux:latest`
- Container user: `user` (sudo enabled, no password)
- Default shell: `/bin/bash`
- Working directory: `/home/user`
