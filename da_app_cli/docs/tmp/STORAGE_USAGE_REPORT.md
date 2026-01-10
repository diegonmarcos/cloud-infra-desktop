# Storage Usage Report - Kubuntu System

**Generated**: 2026-01-09
**System**: Ubuntu 24.04.3 LTS (Noble Numbat) / Kubuntu
**Total Disk**: 118.4 GB
**Used**: 75 GB (68%)
**Available**: 36 GB
**Filesystem**: ext4 on /dev/nvme0n1p5

---

## Storage Breakdown by Category

### 1. OS CORE (Kubuntu System)
**Total**: ~8.9 GB

| Component | Size | Path | Notes |
|-----------|------|------|-------|
| Boot files | 693 MB | `/boot` | Kernels, initramfs, GRUB |
| Binaries | 1.0 GB | `/usr/bin` | System executables |
| System binaries | 63 MB | `/usr/sbin` | Admin executables |
| Shared data | 7.1 GB | `/usr/share` | Docs, icons, themes, locales |
| Configuration | 16 MB | `/etc` | System configs |

**Notes**:
- `/bin` and `/sbin` are symlinks to `/usr/bin` and `/usr/sbin`
- Includes base Ubuntu/Kubuntu OS installation
- KDE Plasma desktop environment files

---

### 2. LIBS SYSTEM-WIDE (Libraries)
**Total**: ~5.9 GB

| Component | Size | Path | Notes |
|-----------|------|------|-------|
| System libraries | 5.8 GB | `/usr/lib` | Shared libraries (.so files) |
| Library executables | 63 MB | `/usr/libexec` | Helper programs |
| 64-bit libs | 4 KB | `/usr/lib64` | Minimal (mostly symlinks) |

**Notes**:
- Includes Qt, KDE frameworks, GTK, Python libs, etc.
- `/lib` and `/lib64` are symlinks to `/usr/lib`

---

### 3. OTHERS SYSTEM-WIDE
**Total**: ~5.2 GB

| Component | Size | Path | Notes |
|-----------|------|------|-------|
| Local installs | 3.3 GB | `/usr/local` | Manually compiled software |
| Optional software | 780 MB | `/opt` | Third-party applications |
| Kernel sources | 151 MB | `/usr/src` | Linux headers |
| Snap packages | 2.7 GB | `/snap` | Snap applications |
| Snap data | 1.6 MB | `/var/snap` | Snap user data |
| Services | 4 KB | `/srv` | Service data (empty) |

**Notes**:
- Snap packages are isolated system-wide installs
- `/usr/local` may contain custom builds

---

### 4. CONTAINERS & VIRTUALIZATION
**Total**: ~40.8 GB

#### Docker (Primary Container Runtime)
| Component | Size | Path | Notes |
|-----------|------|------|-------|
| Docker storage | **38 GB** | `/var/lib/docker` | Images, volumes, containers |
| Podman storage | 640 KB | `/var/lib/containers` | Minimal usage |
| Flatpak runtime | 110 MB | `/var/lib/flatpak` | GUI app runtimes |

#### User Container Data
| Component | Size | Path | Notes |
|-----------|------|------|-------|
| Distrobox data | 196 KB | `~/.local/share/containers` | User containers |
| Flatpak user apps | 48 KB | `~/.local/share/flatpak` | User-installed flatpaks |

#### Application Containers (Home)
| Component | Size | Path | Purpose |
|-----------|------|------|---------|
| GUI apps container | **2.0 GB** | `/home/diego/app_gui` | Flatpak apps (isolated) |
| CLI tools container | 116 KB | `/home/diego/app_cli` | Nix CLI tools |

**Notes**:
- Docker is the primary storage user (38 GB = 51% of used space!)
- Consider running `docker system prune` to clean unused images/containers
- app_gui uses Flatpak for GUI application isolation
- app_cli uses Nix for reproducible CLI tool environments

---

### 5. HOME FILES (User Data)
**Total**: ~9 GB

| Component | Size | Path | Type |
|-----------|------|------|------|
| Git repositories | **6.2 GB** | `~/mnt_git` | Code projects |
| Claude sandbox | 700 MB | `~/claude-sandbox` | Development environment |
| Documents | N/A | `~/Documents` | (symlinked to mnt_git) |
| Vault | N/A | `~/vault` | Encrypted credentials |
| Downloads | N/A | `~/Downloads` | Temp downloads |
| Pictures/Videos | N/A | `~/Pictures`, `~/Videos` | Media files |

**Notes**:
- Main data is in `mnt_git` (front-end, cloud, unix configs)
- Most personal directories may be symlinks or minimal

---

### 6. HOME DOTFILES (Configurations & Caches)
**Total**: ~8.8 GB

#### Application Configurations
| Component | Size | Path | Notes |
|-----------|------|------|-------|
| Config files | **5.1 GB** | `~/.config` | KDE, apps, editors |
| VSCode extensions | **1.2 GB** | `~/.vscode` | Extensions & cache |
| Application cache | **1.1 GB** | `~/.cache` | Temp app data |
| Local app data | 622 MB | `~/.local` | User app data |
| Claude Code data | **581 MB** | `~/.claude` | Session history, logs |
| Nix portable | **617 MB** | `~/.nix-portable` | Portable Nix install |
| npm cache | 74 MB | `~/.npm` | Node.js packages |
| .NET SDK | 248 KB | `~/.dotnet` | .NET configuration |
| Mozilla | 8 KB | `~/.mozilla` | Firefox settings |

**Notes**:
- `.config` is largest (5.1 GB) - contains KDE settings, app configs
- VSCode extensions use significant space (1.2 GB)
- Claude Code stores session history (581 MB - can be cleaned)
- `.cache` can be safely cleaned to recover space
- Nix-portable enables reproducible environments without root

---

## System-Wide Storage (/var)
**Total**: 41 GB

| Component | Size | Notes |
|-----------|------|-------|
| Library data | 40 GB | Primarily Docker (38 GB) |
| Logs | 531 MB | System and application logs |
| Cache | 390 MB | Package manager cache |
| Crash dumps | 87 MB | System crash reports |
| Backups | 18 MB | System backups |

**Notes**:
- `/var/lib` dominates due to Docker
- Logs can be rotated with `journalctl --vacuum-time=7d`

---

## Summary by Category

| Category | Size | % of Used Space | Notes |
|----------|------|-----------------|-------|
| **Containers** | **40.8 GB** | **54%** | Docker (38 GB) + app_gui (2 GB) |
| **Home Files** | **9 GB** | **12%** | Git repos (6.2 GB) + sandbox |
| **Home Dotfiles** | **8.8 GB** | **12%** | Configs (5.1 GB), cache (1.1 GB) |
| **OS Core** | **8.9 GB** | **12%** | Kubuntu system files |
| **System Libs** | **5.9 GB** | **8%** | Shared libraries |
| **Others** | **5.2 GB** | **7%** | /usr/local, /opt, snaps |

**Total Accounted**: ~78.6 GB (system reports 75 GB used)

---

## Recommendations for Space Management

### Immediate Wins (Potential: 5-10 GB)
1. **Clean Docker**:
   ```bash
   docker system prune -a --volumes  # Remove unused images/volumes
   docker image prune -a             # Remove dangling images
   ```

2. **Clean System Cache**:
   ```bash
   sudo apt clean                    # Clear apt cache
   sudo journalctl --vacuum-time=7d  # Rotate logs older than 7 days
   rm -rf ~/.cache/*                 # Clear user cache (1.1 GB)
   ```

3. **Clean Claude Code Sessions**:
   ```bash
   # Archive old sessions (581 MB)
   cd ~/.claude/projects/-home-diego
   tar czf ~/claude-sessions-backup.tar.gz *.jsonl
   # Keep only recent sessions
   find ~/.claude/projects -name "*.jsonl" -mtime +30 -delete
   ```

### Ongoing Maintenance
- Monitor Docker usage: `docker system df`
- Regular cleanup: `docker system prune` weekly
- Review large configs: `du -sh ~/.config/*` and remove unused apps
- Archive old Git branches: Prune merged branches

### Critical Thresholds
- **Warning**: <10 GB free (currently at 36 GB) ✓
- **Critical**: <5 GB free
- **Emergency**: <2 GB free

---

## Notes
- Storage analysis performed using `du`, `df`, `lsblk`
- Some sizes are approximations due to filesystem overhead
- Compressed files may show different sizes when extracted
- Docker images use layered storage (actual usage may vary)
